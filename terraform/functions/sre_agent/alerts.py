"""Парсинг алертов Cloud Monitoring.

Функция parse_alert(payload) -> Incident | None:
  - Маппинг policy_name → kind и severity
  - Валидация обязательных полей
  - Registry-паттерн KIND_HANDLERS для расширяемости

Requirements: 1.1–1.8
"""

from collections.abc import Callable
from datetime import datetime, timezone
from typing import Any

try:
    from .models import Incident
except ImportError:
    from models import Incident  # type: ignore[no-redef]


# ---------------------------------------------------------------------------
# Registry pattern (Req 1.8): new kinds added by registering a handler
# without modifying dispatch logic.
#
# Each handler receives the incident sub-dict and returns (kind, severity).
# ---------------------------------------------------------------------------


def _handle_cpu(incident_data: dict) -> tuple[str, str]:
    """Req 1.1: vm_cpu_high → kind='cpu', severity='warning'."""
    return ("cpu", "warning")


def _handle_mem(incident_data: dict) -> tuple[str, str]:
    """Req 1.2: vm_memory_high → kind='mem', severity='critical'."""
    return ("mem", "critical")


def _handle_pg_fatal(incident_data: dict) -> tuple[str, str]:
    """Req 1.3: postgres_fatal → kind='pg_fatal', severity='critical'."""
    return ("pg_fatal", "critical")


def _handle_n8n_error(incident_data: dict) -> tuple[str, str]:
    """Req 1.4: n8n_error_spike → kind='n8n_error', severity='warning'."""
    return ("n8n_error", "warning")


def _handle_external_unreachable(incident_data: dict) -> tuple[str, str]:
    """Req 1.5: external_unreachable → kind='external_unreachable', severity='critical'."""
    return ("external_unreachable", "critical")


KIND_HANDLERS: dict[str, Callable[[dict], tuple[str, str]]] = {
    "vm_cpu_high": _handle_cpu,
    "vm_memory_high": _handle_mem,
    "postgres_fatal": _handle_pg_fatal,
    "n8n_error_spike": _handle_n8n_error,
    "external_unreachable": _handle_external_unreachable,
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _parse_timestamp(value: str | None) -> datetime:
    """Parse ISO-8601 timestamp string to datetime (UTC).

    Falls back to Unix epoch (1970-01-01T00:00:00Z) if value is None or
    unparseable. Using a fixed sentinel ensures determinism (P3): the same
    payload always produces the same Incident regardless of wall-clock time.
    """
    _EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
    if not value:
        return _EPOCH
    try:
        # Handle 'Z' suffix and standard ISO format
        cleaned = value.replace("Z", "+00:00")
        return datetime.fromisoformat(cleaned)
    except (ValueError, TypeError):
        return _EPOCH


def _extract_vm_name(resource_name: str | None) -> str:
    """Extract VM instance name from GCP resource_name path.

    Example: 'projects/p/zones/z/instances/my-vm' → 'my-vm'
    """
    if not resource_name:
        return ""
    parts = resource_name.split("/")
    # Format: projects/{project}/zones/{zone}/instances/{instance}
    try:
        idx = parts.index("instances")
        return parts[idx + 1]
    except (ValueError, IndexError):
        # Fallback: return last segment
        return parts[-1] if parts else ""


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def parse_alert(payload: Any) -> "Incident | None":
    """Parse a Cloud Monitoring alert payload into an Incident.

    Returns None if:
      - payload is None or not a dict
      - required field incident.incident_id is missing/empty
      - required field incident.policy_name is missing/empty
      - policy_name is not in KIND_HANDLERS registry

    Deterministic (P3): same payload always produces the same Incident.

    Args:
        payload: Raw Cloud Monitoring alert payload dict.

    Returns:
        Incident model or None for invalid/unrecognized payloads.
    """
    # --- Validate payload structure ---
    if not isinstance(payload, dict):
        return None

    incident_data = payload.get("incident")
    if not isinstance(incident_data, dict):
        return None

    # --- Validate required fields (Req 1.7) ---
    incident_id = incident_data.get("incident_id")
    if not incident_id:  # None or empty string
        return None

    policy_name = incident_data.get("policy_name")
    if not policy_name:  # None or empty string
        return None

    # --- Dispatch via registry (Req 1.8) ---
    handler = KIND_HANDLERS.get(policy_name)
    if handler is None:
        return None

    kind, severity = handler(incident_data)

    # --- Extract started_at (fallback to observed_time) ---
    started_at_raw = incident_data.get("started_at") or incident_data.get("observed_time")
    started_at = _parse_timestamp(started_at_raw)

    # --- Extract resource info ---
    resource_name = incident_data.get("resource_name", "")
    vm_name = _extract_vm_name(resource_name)

    resource: dict[str, str] = {}
    if vm_name:
        resource["vm"] = vm_name

    # Extract public_host if available in resource labels or condition
    resource_labels = incident_data.get("resource", {})
    if isinstance(resource_labels, dict):
        labels = resource_labels.get("labels", {})
        if isinstance(labels, dict) and "public_host" in labels:
            resource["public_host"] = labels["public_host"]

    # --- Build Incident (deterministic — no randomness, no timestamps from clock) ---
    return Incident(
        id=incident_id,
        kind=kind,
        severity=severity,
        started_at=started_at,
        resource=resource,
        raw_payload=payload,
        source="cloud-monitoring",
    )
