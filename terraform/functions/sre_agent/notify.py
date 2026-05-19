"""Отправка диагноза в Telegram.

Функции:
  - notify_telegram(incident, diagnosis, correlation_id) — полное сообщение (🚨/🔍/🛠)
  - notify_telegram_brief(incident, reason, vm_age) — короткое при подавлении
  - notify_telegram_correlation_update(correlation_id, incident) — обновление severity

Retry до 3 раз с экспоненциальным backoff для HTTP >= 400.
Блокировка отправки при отсутствии incident.id.
Структурированный лог event=notify_fail при исчерпании retry.

Requirements: 3.1–3.7, 4.3
"""

from __future__ import annotations

import logging
import time
from typing import Optional

import httpx

from sre_agent.models import Diagnosis, Incident
from sre_agent.settings import settings

logger = logging.getLogger(__name__)

# MarkdownV2 special characters that must be escaped
_MARKDOWN_V2_SPECIAL = r"_*[]()~`>#+-=|{}.!"


def _escape_markdown_v2(text: str) -> str:
    """Escape special characters for Telegram MarkdownV2 format.

    All characters in _MARKDOWN_V2_SPECIAL are prefixed with backslash.
    """
    if not text:
        return text
    result = []
    for ch in text:
        if ch in _MARKDOWN_V2_SPECIAL:
            result.append("\\")
        result.append(ch)
    return "".join(result)


def _send_telegram_message(
    text: str,
    *,
    incident_id: str = "",
) -> Optional[dict]:
    """Send a message to Telegram with retry logic.

    Retry up to 3 times with exponential backoff (1s, 2s, 4s) ONLY for
    HTTP status >= 400. Network timeouts and JSON parse errors do NOT
    trigger retry.

    Args:
        text: Message text to send.
        incident_id: Incident ID for structured logging on failure.

    Returns:
        Parsed JSON response dict on success, None on failure.
    """
    url = f"https://api.telegram.org/bot{settings.tg_bot_token}/sendMessage"
    payload = {
        "chat_id": settings.tg_chat_id,
        "text": text,
        "parse_mode": "MarkdownV2",
    }

    max_retries = 3
    last_error: Optional[str] = None

    with httpx.Client() as client:
        for attempt in range(1, max_retries + 1):
            try:
                response = client.post(url, json=payload, timeout=30.0)
                response.raise_for_status()
                return response.json()
            except httpx.HTTPStatusError as exc:
                last_error = f"HTTP {exc.response.status_code}: {exc}"
                if attempt < max_retries:
                    backoff = 2 ** (attempt - 1)  # 1, 2, 4
                    time.sleep(backoff)
                # Continue to next attempt or fall through
            except httpx.TimeoutException as exc:
                # Network timeouts do NOT trigger retry
                last_error = f"Timeout: {exc}"
                break
            except Exception as exc:
                # JSON parse errors and other exceptions do NOT trigger retry
                last_error = f"Error: {exc}"
                break

    # All retries exhausted or non-retryable error
    logger.error(
        "event=notify_fail incident_id=%s last_error=%s",
        incident_id or "unknown",
        last_error,
    )
    return None


def _check_incident_id(incident: Incident, func_name: str) -> bool:
    """Check that incident.id is present. Log and return False if missing."""
    if not incident.id:
        logger.warning(
            "event=notify_blocked reason=missing_incident_id func=%s",
            func_name,
        )
        return False
    return True


def notify_telegram(
    incident: Incident,
    diagnosis: Diagnosis,
    correlation_id: str,
) -> Optional[dict]:
    """Send full diagnosis message to Telegram with three sections.

    Sections:
      🚨 kind / severity / resource (what happened)
      🔍 hypothesis with evidence (root-cause)
      🛠 suggested_fix + optional suggested_command in monospace

    Args:
        incident: The incident being diagnosed.
        diagnosis: The diagnosis result (LLM or rule-based).
        correlation_id: Correlation window ID.

    Returns:
        Telegram API response dict on success, None on failure/block.
    """
    if not _check_incident_id(incident, "notify_telegram"):
        return None

    # Build resource string
    resource_str = incident.resource.get("vm", incident.resource.get("public_host", "unknown"))

    # Section 1: What happened
    # incident.id goes inside backticks (inline code) — no escaping needed there
    section_alert = (
        f"🚨 *Incident*\n"
        f"ID: `{incident.id}`\n"
        f"Kind: {_escape_markdown_v2(incident.kind)}\n"
        f"Severity: {_escape_markdown_v2(incident.severity)}\n"
        f"Resource: {_escape_markdown_v2(resource_str)}"
    )

    # Section 2: Root-cause hypothesis
    section_diagnosis = (
        f"🔍 *Root Cause*\n"
        f"{_escape_markdown_v2(diagnosis.hypothesis)}\n"
        f"Confidence: {_escape_markdown_v2(diagnosis.confidence)}"
    )

    # Section 3: What to do
    fix_text = _escape_markdown_v2(diagnosis.suggested_fix)
    section_fix = f"🛠 *Action*\n{fix_text}"
    if diagnosis.suggested_command:
        section_fix += f"\n```\n{diagnosis.suggested_command}\n```"

    # Combine
    text = f"{section_alert}\n\n{section_diagnosis}\n\n{section_fix}"

    return _send_telegram_message(text, incident_id=incident.id)


def notify_telegram_brief(
    incident: Incident,
    reason: str,
    vm_age: Optional[int] = None,
) -> Optional[dict]:
    """Send brief suppression notification to Telegram.

    Used when incident is suppressed (live migration or bootstrap grace).

    Args:
        incident: The suppressed incident.
        reason: Suppression reason ("live_migration" or "bootstrap_grace").
        vm_age: VM age in seconds (optional, for bootstrap grace).

    Returns:
        Telegram API response dict on success, None on failure/block.
    """
    if not _check_incident_id(incident, "notify_telegram_brief"):
        return None

    if reason == "live_migration":
        text = (
            f"🔄 *Подавлено: live migration*\n"
            f"ID: `{incident.id}`\n"
            f"Kind: {_escape_markdown_v2(incident.kind)}"
        )
    elif reason == "bootstrap_grace":
        age_str = f", vm\\_age\\={vm_age}s" if vm_age is not None else ""
        text = (
            f"🛠 *Подавлено: bootstrap grace*\n"
            f"ID: `{incident.id}`\n"
            f"Kind: {_escape_markdown_v2(incident.kind)}{age_str}"
        )
    else:
        text = (
            f"🔄 *Подавлено: {_escape_markdown_v2(reason)}*\n"
            f"ID: `{incident.id}`\n"
            f"Kind: {_escape_markdown_v2(incident.kind)}"
        )

    return _send_telegram_message(text, incident_id=incident.id)


def notify_telegram_correlation_update(
    correlation_id: str,
    incident: Incident,
) -> Optional[dict]:
    """Send correlation severity escalation update to Telegram.

    Used when a new signal raises severity in an existing correlation window.

    Args:
        correlation_id: The correlation window ID.
        incident: The incident that triggered the escalation.

    Returns:
        Telegram API response dict on success, None on failure/block.
    """
    if not _check_incident_id(incident, "notify_telegram_correlation_update"):
        return None

    text = (
        f"⚠️ *Severity escalation*\n"
        f"Correlation: `{correlation_id}`\n"
        f"Incident: `{incident.id}`\n"
        f"Kind: {_escape_markdown_v2(incident.kind)}\n"
        f"New severity: {_escape_markdown_v2(incident.severity)}"
    )

    return _send_telegram_message(text, incident_id=incident.id)
