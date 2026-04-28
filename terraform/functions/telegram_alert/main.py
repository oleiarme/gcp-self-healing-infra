"""Cloud Function: forward GCP Monitoring alerts to a Telegram topic."""

import base64
import json
import os
import urllib.request
import urllib.error

BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
CHAT_ID = os.environ["TELEGRAM_CHAT_ID"]
THREAD_ID = os.environ.get("TELEGRAM_THREAD_ID", "")

SEVERITY_EMOJI = {
    "CRITICAL": "🔴",
    "ERROR": "🔴",
    "WARNING": "🟡",
    "INFO": "🔵",
}


def _send_telegram(text: str) -> None:
    payload: dict = {
        "chat_id": CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    if THREAD_ID:
        payload["message_thread_id"] = int(THREAD_ID)

    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise RuntimeError(f"Telegram API {exc.code}: {body}") from exc


def _format_alert(incident: dict) -> str:
    from html import escape

    severity = incident.get("severity", "UNKNOWN")
    emoji = SEVERITY_EMOJI.get(severity, "⚪")
    state = incident.get("state", "unknown")
    policy = escape(incident.get("policy_name", "—"))
    summary = escape(incident.get("summary", ""))
    url = incident.get("url", "")
    resource = escape(incident.get("resource_name", ""))
    condition = escape(incident.get("condition_name", ""))

    state_text = "🔥 OPEN" if state == "open" else "✅ CLOSED"

    lines = [
        f"{emoji} <b>{policy}</b>",
        f"Status: {state_text}",
        f"Severity: {severity}",
    ]
    if condition:
        lines.append(f"Condition: {condition}")
    if resource:
        lines.append(f"Resource: <code>{resource}</code>")
    if summary:
        lines.append(f"\n{summary}")
    if url:
        lines.append(f'\n<a href="{escape(url, quote=True)}">Open in Cloud Console</a>')

    return "\n".join(lines)


def handle_pubsub(event, context):
    """Entry point for Cloud Functions Gen1 Pub/Sub trigger."""
    raw = base64.b64decode(event["data"]).decode()
    payload = json.loads(raw)
    incident = payload.get("incident", {})
    text = _format_alert(incident)
    _send_telegram(text)