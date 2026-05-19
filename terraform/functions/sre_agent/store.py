"""Хранилище Firestore: дедуп, корреляция, бюджет.

Функции:
  - is_duplicate(incident_id) — проверка TTL 1 час
  - mark_seen(incident_id, ttl_seconds) — запись документа
  - today_cost_usd() — агрегация cost за текущий день UTC
  - persist_diagnosis(diagnosis, correlation_id) — запись в коллекцию diagnoses
  - persist_diagnosis_skipped(incident, reason) — запись подавленного инцидента
  - find_or_create_incident_window(incident) — корреляция same-kind/cross-kind

Requirements: 4.1, 4.2, 9.1, 9.5, 10.1, 10.4
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING

from google.cloud import firestore

from .settings import settings

if TYPE_CHECKING:
    from .models import Diagnosis, Incident

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Time helper (mockable for tests)
# ---------------------------------------------------------------------------


def _utcnow() -> datetime:
    """Return current UTC time. Extracted for testability."""
    return datetime.now(tz=timezone.utc)


# ---------------------------------------------------------------------------
# Firestore client singleton (lazy init)
# ---------------------------------------------------------------------------

_db: firestore.Client | None = None


def _get_db() -> firestore.Client:
    """Return a cached Firestore client instance."""
    global _db
    if _db is None:
        _db = firestore.Client(project=settings.project_id)
    return _db


# ---------------------------------------------------------------------------
# Deduplication (Req 4.1)
# ---------------------------------------------------------------------------


def is_duplicate(incident_id: str) -> bool:
    """Check if incident was already processed within TTL window.

    Returns True if Firestore document `incidents/{id}` exists and TTL
    has not expired. On Firestore error, returns False (graceful degradation
    per Req 10.1 — allow processing to continue).
    """
    try:
        db = _get_db()
        doc_ref = db.collection("incidents").document(incident_id)
        doc = doc_ref.get()

        if not doc.exists:
            return False

        data = doc.to_dict()
        ttl_expires_at = data.get("ttl_expires_at")
        if ttl_expires_at is None:
            return True

        now = _utcnow()
        if now > ttl_expires_at:
            return False

        return True

    except Exception as exc:
        log.warning(
            "event=firestore_unavailable operation=dedup error=%s",
            str(exc),
            exc_info=True,
        )
        return False


def mark_seen(incident_id: str, ttl_seconds: int = 3600) -> None:
    """Write dedup document to Firestore `incidents/{id}`.

    Document contains `seen_at` and `ttl_expires_at` for TTL-based expiry.
    On Firestore error, logs warning and continues (Req 10.1).
    """
    try:
        db = _get_db()
        now = _utcnow()
        doc_ref = db.collection("incidents").document(incident_id)
        doc_ref.set({
            "seen_at": now,
            "ttl_expires_at": now + timedelta(seconds=ttl_seconds),
        })
    except Exception as exc:
        log.warning(
            "event=firestore_unavailable operation=mark_seen error=%s",
            str(exc),
            exc_info=True,
        )


# ---------------------------------------------------------------------------
# Budget tracking (Req 4.2)
# ---------------------------------------------------------------------------


def today_cost_usd() -> float:
    """Aggregate cost_usd from diagnoses collection for current UTC day.

    On Firestore error, returns budget value (conservative path per Req 10.4)
    to trigger rule-based fallback and prevent uncontrolled LLM spending.
    """
    try:
        db = _get_db()
        now = _utcnow()
        day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        day_end = day_start + timedelta(days=1)

        query = (
            db.collection("diagnoses")
            .where("created_at", ">=", day_start)
            .where("created_at", "<", day_end)
        )

        total = 0.0
        for doc in query.stream():
            data = doc.to_dict()
            total += data.get("cost_usd", 0.0)

        return total

    except Exception as exc:
        log.warning(
            "event=firestore_unavailable operation=budget_check error=%s",
            str(exc),
            exc_info=True,
        )
        # Conservative: return budget to force rule-based fallback
        return settings.llm_budget_usd_per_day


# ---------------------------------------------------------------------------
# Persistence (Req 4.1, 10.1)
# ---------------------------------------------------------------------------


def persist_diagnosis(diagnosis: "Diagnosis", correlation_id: str) -> None:
    """Write diagnosis to `diagnoses` collection with 30-day TTL.

    On Firestore error, logs warning and continues (Req 10.1).
    """
    try:
        db = _get_db()
        ttl_expires_at = diagnosis.created_at + timedelta(days=30)

        doc_data = {
            "hypothesis": diagnosis.hypothesis,
            "evidence_refs": diagnosis.evidence_refs,
            "confidence": diagnosis.confidence,
            "suggested_fix": diagnosis.suggested_fix,
            "suggested_command": diagnosis.suggested_command,
            "model": diagnosis.model,
            "tokens_in": diagnosis.tokens_in,
            "tokens_out": diagnosis.tokens_out,
            "cost_usd": diagnosis.cost_usd,
            "created_at": diagnosis.created_at,
            "correlation_id": correlation_id,
            "ttl_expires_at": ttl_expires_at,
        }

        db.collection("diagnoses").add(doc_data)

    except Exception as exc:
        log.warning(
            "event=firestore_unavailable operation=persist_diagnosis error=%s",
            str(exc),
            exc_info=True,
        )


# ---------------------------------------------------------------------------
# Priority matrix (Req 9.5)
# ---------------------------------------------------------------------------

# Total ordering: pg_fatal > mem > cpu > external_unreachable > n8n_error
_KIND_PRIORITY: dict[str, int] = {
    "pg_fatal": 5,
    "mem": 4,
    "cpu": 3,
    "external_unreachable": 2,
    "n8n_error": 1,
}


def _kind_priority(kind: str) -> int:
    """Return numeric priority for incident kind. Unknown kinds get 0."""
    return _KIND_PRIORITY.get(kind, 0)


# ---------------------------------------------------------------------------
# Resource key resolution
# ---------------------------------------------------------------------------


def _resource_key(incident: "Incident") -> str:
    """Extract resource key from incident: resource.vm or resource.public_host."""
    return incident.resource.get("vm") or incident.resource.get("public_host", "unknown")


# ---------------------------------------------------------------------------
# Correlation (Req 9.1, 9.5)
# ---------------------------------------------------------------------------


def find_or_create_incident_window(incident: "Incident") -> tuple[str, bool]:
    """Find or create an incident correlation window.

    Queries Firestore collection `incident_windows` for an open window
    matching the incident's resource key. If found and within correlation
    window (same-kind 90s or cross-kind 180s), atomically updates the
    window document via Firestore Transaction. Otherwise creates a new window.

    Correlation rules (Req 9.1):
    - Same-kind: last_signal_at + 90s > incident.started_at
    - Cross-kind: last_signal_at + 180s > incident.started_at
    - Window max open time: 30 minutes from opened_at

    Priority matrix (Req 9.5):
    - pg_fatal > mem > cpu > external_unreachable > n8n_error
    - When higher-priority signal arrives, severity is upgraded to incident's severity

    Args:
        incident: The normalized Incident to correlate.

    Returns:
        Tuple (window_id, correlated) where correlated=False means new window
        created (first signal), correlated=True means joined existing window.

    On Firestore error, returns a fallback UUID window_id with correlated=False
    (graceful degradation per Req 10.1).
    """
    try:
        db = _get_db()
        now = _utcnow()
        resource = _resource_key(incident)

        # Query open windows for this resource
        # Window is "open" if opened_at is within last 30 minutes
        window_cutoff = now - timedelta(seconds=settings.window_max_open_seconds)

        query = (
            db.collection("incident_windows")
            .where("resource_key", "==", resource)
            .where("opened_at", ">=", window_cutoff)
            .where("opened_at", "<=", now)
        )

        # Find a matching window within correlation time bounds
        matched_window = None
        for doc in query.stream():
            window_data = doc.to_dict()
            window_opened_at = window_data["opened_at"]
            window_last_signal = window_data["last_signal_at"]
            window_primary_kind = window_data["primary_kind"]

            # Check if window is still within max open time (30 min)
            if (now - window_opened_at).total_seconds() > settings.window_max_open_seconds:
                continue

            # Determine correlation window based on kind match
            if incident.kind == window_primary_kind:
                # Same-kind: last_signal_at + 90s > incident.started_at
                max_gap = settings.correlation_window_sec
            else:
                # Cross-kind: last_signal_at + 180s > incident.started_at
                max_gap = settings.cross_kind_correlation_window_sec

            # Check if incident falls within the correlation window
            # Per Req 9.1: last_signal_at + CORRELATION_WINDOW_SEC > incident.started_at
            gap_seconds = (incident.started_at - window_last_signal).total_seconds()
            if gap_seconds <= max_gap:
                matched_window = (doc.id, window_data)
                break

        if matched_window is None:
            # No matching window — create a new one
            new_window_data = {
                "primary_kind": incident.kind,
                "resource_key": resource,
                "opened_at": now,
                "last_signal_at": incident.started_at,
                "co_signals": [],
                "incident_ids": [incident.id],
                "severity": incident.severity,
            }
            _, doc_ref = db.collection("incident_windows").add(new_window_data)
            log.info(
                "event=correlation_new_window window_id=%s kind=%s resource=%s",
                doc_ref.id,
                incident.kind,
                resource,
            )
            return (doc_ref.id, False)

        # Correlate into existing window via Firestore Transaction
        window_id, window_data = matched_window

        # Determine if severity should be upgraded
        incoming_priority = _kind_priority(incident.kind)
        existing_priority = _kind_priority(window_data["primary_kind"])

        update_data: dict = {
            "last_signal_at": incident.started_at,
            "co_signals": firestore.ArrayUnion([incident.kind]),
            "incident_ids": firestore.ArrayUnion([incident.id]),
        }

        # Upgrade severity if incoming signal has higher priority
        if incoming_priority > existing_priority:
            update_data["severity"] = incident.severity

        doc_ref = db.collection("incident_windows").document(window_id)

        # Atomic update via Firestore Transaction (Req 9.1)
        transaction = db.transaction()

        @firestore.transactional
        def _update_in_transaction(txn):
            txn.update(doc_ref, update_data)

        _update_in_transaction(transaction)

        log.info(
            "event=correlated window_id=%s kind=%s resource=%s",
            window_id,
            incident.kind,
            resource,
        )
        return (window_id, True)

    except Exception as exc:
        log.warning(
            "event=firestore_unavailable operation=correlation error=%s",
            str(exc),
            exc_info=True,
        )
        # Graceful degradation: return a fallback window ID
        fallback_id = f"fallback-{uuid.uuid4().hex[:12]}"
        return (fallback_id, False)


def persist_diagnosis_skipped(incident: "Incident", reason: str) -> None:
    """Write suppressed incident record to `diagnoses_skipped` collection.

    On Firestore error, logs warning and continues (Req 10.1).
    """
    try:
        db = _get_db()
        now = _utcnow()

        doc_data = {
            "incident_id": incident.id,
            "kind": incident.kind,
            "severity": incident.severity,
            "reason": reason,
            "started_at": incident.started_at,
            "resource": incident.resource,
            "skipped_at": now,
        }

        db.collection("diagnoses_skipped").add(doc_data)

    except Exception as exc:
        log.warning(
            "event=firestore_unavailable operation=persist_skipped error=%s",
            str(exc),
            exc_info=True,
        )
