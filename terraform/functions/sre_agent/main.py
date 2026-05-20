"""Entry-point Cloud Function: sre_agent(cloud_event).

Оркестрирует полный цикл обработки инцидента:
  Layer 1: Idempotency dedup
  Layer 2: Suppression (Live Migration / bootstrap grace)
  Layer 3: Correlation (same-kind / cross-kind)
  Layer 4: gather + redact + token truncation + LLM (или fallback)
  Layer 5: notify + persist

Requirements: 1.7, 4.1–4.4, 7.2, 7.3, 9.2–9.7, 10.1–10.3
"""

from __future__ import annotations

import os
import sys

# Cloud Functions Gen2 runs main.py as a top-level script.
# Ensure the source directory is on sys.path so that both
# `from sre_agent.X import Y` (tests) and `from X import Y` (runtime) work.
_current_dir = os.path.dirname(os.path.abspath(__file__))
if _current_dir not in sys.path:
    sys.path.insert(0, _current_dir)
    __package__ = "sre_agent"



import base64
import json
import logging
import threading
from typing import Any

try:
    from .alerts import parse_alert
    from .context import (
        gather_context,
        instance_age_seconds_cached,
        is_live_migration_in_window,
        truncate_context,
    )
    from .llm import analyze_with_llm
    from .notify import notify_telegram, notify_telegram_brief
    from .redact import redact_signals
    from .rules import rule_based_diagnose
    from .settings import settings
    from .store import (
        find_or_create_incident_window,
        is_duplicate,
        mark_seen,
        persist_diagnosis,
        persist_diagnosis_skipped,
        today_cost_usd,
    )
except ImportError:
    # Cloud Functions Gen2 runs main.py as top-level script (no package context)
    from alerts import parse_alert  # type: ignore[no-redef]
    from context import (  # type: ignore[no-redef]
        gather_context,
        instance_age_seconds_cached,
        is_live_migration_in_window,
        truncate_context,
    )
    from llm import analyze_with_llm  # type: ignore[no-redef]
    from notify import notify_telegram, notify_telegram_brief  # type: ignore[no-redef]
    from redact import redact_signals  # type: ignore[no-redef]
    from rules import rule_based_diagnose  # type: ignore[no-redef]
    from settings import settings  # type: ignore[no-redef]
    from store import (  # type: ignore[no-redef]
        find_or_create_incident_window,
        is_duplicate,
        mark_seen,
        persist_diagnosis,
        persist_diagnosis_skipped,
        today_cost_usd,
    )

logger = logging.getLogger(__name__)


def _extract_payload(cloud_event: Any) -> Any:
    """Extract alert payload from CloudEvent.

    Cloud Functions Gen2 with Pub/Sub trigger delivers data in two formats:
    1. Direct dict (e.g. in tests or direct invocation) — use as-is.
    2. Pub/Sub message envelope with base64-encoded data in
       cloud_event.data["message"]["data"] — decode and parse JSON.

    Args:
        cloud_event: CloudEvent from Pub/Sub trigger.

    Returns:
        Parsed alert payload dict, or the raw data if decoding fails.
    """
    data = cloud_event.data

    # If data is a dict with a "message" key containing base64 "data",
    # this is the Pub/Sub CloudEvent envelope format.
    if isinstance(data, dict) and "message" in data:
        message = data["message"]
        if isinstance(message, dict) and "data" in message:
            try:
                decoded = base64.b64decode(message["data"])
                return json.loads(decoded)
            except (ValueError, json.JSONDecodeError):
                return None

    # Direct dict payload (tests, direct invocation)
    return data


def sre_agent(cloud_event: Any) -> str:
    """Entry-point for Cloud Function Gen2 triggered by Pub/Sub.

    Orchestrates the full incident processing cycle:
      1. Kill-switch check
      2. Parse alert payload (extract Pub/Sub message → base64 decode → JSON)
      3. Log invocation
      4. Idempotency dedup
      5. Suppression (Live Migration / bootstrap grace)
      6. Correlation (same-kind / cross-kind windows)
      7. Gather context + redact + truncate
      8. LLM analysis (or rule-based fallback)
      9. Notify Telegram + persist diagnosis

    Args:
        cloud_event: CloudEvent from Pub/Sub trigger containing alert payload.

    Returns:
        Status string: "disabled", "bad_payload", "duplicate",
        "suppressed:live_migration", "suppressed:bootstrap_grace",
        "correlated", or "ok".
    """
    # ─── Layer 0: Kill-switch (Req 7.2) ───────────────────────────────
    if not settings.enabled:
        return "disabled"

    # ─── Parse alert payload ──────────────────────────────────────────
    payload = _extract_payload(cloud_event)
    incident = parse_alert(payload)
    if incident is None:
        return "bad_payload"

    # ─── Structured log: event=invocation (Req 7.3) ───────────────────
    logger.info(
        "Incident received",
        extra={
            "event": "invocation",
            "incident_id": incident.id,
            "kind": incident.kind,
            "severity": incident.severity,
        },
    )

    # ─── Layer 1: Idempotency dedup (Req 4.1) ────────────────────────
    if is_duplicate(incident.id):
        return "duplicate"

    mark_seen(incident.id)

    # ─── Layer 2: Suppression (Req 9.2, 9.3) ─────────────────────────
    # 2a: Live Migration ±300s
    if is_live_migration_in_window(incident):
        notify_telegram_brief(incident, "live_migration")
        persist_diagnosis_skipped(incident, "live_migration")
        return "suppressed:live_migration"

    # 2b: Bootstrap grace — instance age < BOOTSTRAP_GRACE_SECONDS
    #     Only for external_unreachable and n8n_error kinds
    if incident.kind in ("external_unreachable", "n8n_error"):
        vm_age = instance_age_seconds_cached(incident)
        if vm_age is not None and vm_age < settings.bootstrap_grace_seconds:
            notify_telegram_brief(incident, "bootstrap_grace", vm_age=vm_age)
            persist_diagnosis_skipped(incident, "bootstrap_grace")
            return "suppressed:bootstrap_grace"

    # ─── Layer 3: Correlation (Req 9.1) ───────────────────────────────
    correlation_id, correlated = find_or_create_incident_window(incident)
    if correlated:
        return "correlated"

    # ─── Layer 4: gather + redact + truncate + LLM/fallback ───────────
    # Use a timeout guard for the processing phase
    diagnosis = _process_with_timeout(incident, correlation_id)

    # ─── Layer 5: notify + persist ────────────────────────────────────
    notify_telegram(incident, diagnosis, correlation_id)
    persist_diagnosis(diagnosis, correlation_id)

    return "ok"


def _process_with_timeout(incident, correlation_id: str | None):
    """Run gather/redact/truncate/LLM within PROCESSING_TIMEOUT_SECONDS.

    On timeout, falls back to rule_based_diagnose with partial context.

    Args:
        incident: Parsed incident.
        correlation_id: Correlation window ID.

    Returns:
        Diagnosis object (from LLM or rule-based fallback).
    """
    timeout_sec = settings.processing_timeout_seconds
    result_holder: list = []
    error_holder: list = []

    def _do_processing():
        try:
            diag = _gather_and_analyze(incident, correlation_id)
            result_holder.append(diag)
        except Exception as exc:
            error_holder.append(exc)

    worker = threading.Thread(target=_do_processing, daemon=True)
    worker.start()
    worker.join(timeout=timeout_sec)

    if worker.is_alive():
        # Timeout — use rule-based fallback
        logger.warning(
            "Processing timeout exceeded",
            extra={
                "event": "processing_timeout",
                "incident_id": incident.id,
                "timeout_seconds": timeout_sec,
            },
        )
        diagnosis = rule_based_diagnose(incident, [])
        diagnosis.hypothesis = f"[timeout] {diagnosis.hypothesis}"
        return diagnosis

    if error_holder:
        # Unexpected error during processing — fallback
        logger.error(
            "Processing error",
            extra={
                "event": "processing_error",
                "incident_id": incident.id,
                "error": str(error_holder[0]),
            },
        )
        diagnosis = rule_based_diagnose(incident, [])
        diagnosis.hypothesis = f"[processing error] {diagnosis.hypothesis}"
        return diagnosis

    return result_holder[0]


def _gather_and_analyze(incident, correlation_id: str | None):
    """Gather context, redact, truncate, and run LLM or fallback.

    Args:
        incident: Parsed incident.
        correlation_id: Correlation window ID.

    Returns:
        Diagnosis object.
    """
    # Gather context
    signals, metadata = gather_context(incident, settings)

    # Redact secrets
    signals = redact_signals(signals)

    # Truncate to token budget
    signals = truncate_context(signals)

    # Budget check (Req 4.2, 4.4)
    if today_cost_usd() >= settings.llm_budget_usd_per_day:
        logger.info(
            "Budget exhausted, using rule-based fallback",
            extra={
                "event": "budget_exhausted",
                "incident_id": incident.id,
            },
        )
        diagnosis = rule_based_diagnose(incident, signals)
        diagnosis.hypothesis = f"[budget exhausted] {diagnosis.hypothesis}"
        return diagnosis

    # LLM call with fallback (Req 6.4)
    try:
        diagnosis = analyze_with_llm(incident, signals)
    except Exception as exc:
        reason = str(exc) or type(exc).__name__
        logger.warning(
            "LLM call failed, using rule-based fallback",
            extra={
                "event": "llm_failed",
                "incident_id": incident.id,
                "error": reason,
            },
        )
        diagnosis = rule_based_diagnose(incident, signals)
        diagnosis.hypothesis = f"[llm down: {reason}] {diagnosis.hypothesis}"

    return diagnosis
