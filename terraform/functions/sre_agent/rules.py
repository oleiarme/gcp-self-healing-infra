"""Rule-based fallback диагностика.

Функция rule_based_diagnose(incident, signals) -> Diagnosis:
  - Детерминистический классификатор: OOM, postgres FATAL, ECONNREFUSED, unknown
  - Всегда confidence="low", model="rule-based-v1"
  - Используется при отказе LLM или исчерпании бюджета

Requirements: 6.4, 6.5
"""

from datetime import datetime, timezone

try:
    from .models import Diagnosis, Incident, Signal
except ImportError:
    from models import Diagnosis, Incident, Signal  # type: ignore[no-redef]


def rule_based_diagnose(incident: Incident, signals: list[Signal]) -> Diagnosis:
    """Deterministic rule-based fallback classifier.

    Classifies incidents into: OOM, postgres FATAL, ECONNREFUSED, or unknown.
    Always returns confidence="low", model="rule-based-v1", zero tokens/cost.

    Args:
        incident: Normalized incident from Cloud Monitoring.
        signals: Collected context signals (logs, metrics, probe results).

    Returns:
        Diagnosis with rule-based classification.
    """
    all_log_texts = _extract_log_texts(signals)
    probe_data = _extract_probe_data(signals)

    # Try classifiers in priority order
    hypothesis, suggested_fix, evidence_refs = _classify(
        incident, all_log_texts, probe_data
    )

    return Diagnosis(
        hypothesis=hypothesis,
        evidence_refs=evidence_refs,
        confidence="low",
        suggested_fix=suggested_fix,
        suggested_command=None,
        model="rule-based-v1",
        tokens_in=0,
        tokens_out=0,
        cost_usd=0.0,
        created_at=datetime.now(timezone.utc),
    )


def _classify(
    incident: Incident,
    log_texts: list[str],
    probe_data: dict | None,
) -> tuple[str, str, list[str]]:
    """Run classification rules in priority order.

    Returns (hypothesis, suggested_fix, evidence_refs).
    """
    # 1. OOM detection
    if incident.kind == "mem" or _has_oom_pattern(log_texts):
        evidence = _find_matching_lines(log_texts, _OOM_PATTERNS)
        return (
            "OOM (Out of Memory) — process killed by kernel OOM killer",
            "Check container memory limits. Consider increasing VM memory or "
            "reducing n8n workflow concurrency. Review recent workflow changes "
            "for memory leaks.",
            evidence,
        )

    # 2. Postgres FATAL/PANIC detection
    if incident.kind == "pg_fatal" or _has_postgres_fatal_pattern(log_texts):
        evidence = _find_matching_lines(log_texts, _PG_FATAL_PATTERNS)
        return (
            "Postgres FATAL/PANIC — database process terminated abnormally",
            "Check postgres logs for root cause (authentication failure, "
            "shared memory exhaustion, corrupted data). Consider restarting "
            "postgres container if persistent.",
            evidence,
        )

    # 3. ECONNREFUSED detection (n8n can't reach postgres or other services)
    if _has_econnrefused_pattern(log_texts) or _has_connection_refused_probe(probe_data):
        evidence = _find_matching_lines(log_texts, _ECONNREFUSED_PATTERNS)
        if not evidence and probe_data:
            evidence = [f"probe:{k}={v}" for k, v in probe_data.items() if "error" in k]
        return (
            "ECONNREFUSED — connection refused to downstream service",
            "Verify target service is running (postgres, n8n, cloudflared). "
            "Check docker container status and network connectivity.",
            evidence,
        )

    # 4. External unreachable with probe data
    if incident.kind == "external_unreachable" and probe_data:
        evidence = [f"probe:{k}={v}" for k, v in probe_data.items() if "error" in k or "ok" in k]
        return (
            "External unreachable — service not responding to external probes",
            "Check cloudflared tunnel status, DNS resolution, and TLS "
            "certificate validity. Verify VM is running and healthy.",
            evidence,
        )

    # 5. Unknown / generic fallback
    return _unknown_fallback(incident, log_texts)


# --- Pattern constants ---

_OOM_PATTERNS = [
    "out of memory",
    "oom",
    "killed process",
    "oom_killed",
    "cannot allocate memory",
    "memory allocation failed",
]

_PG_FATAL_PATTERNS = [
    "fatal",
    "panic",
    "deadlock detected",
    "could not connect",
    "terminating connection",
    "shared memory",
]

_ECONNREFUSED_PATTERNS = [
    "econnrefused",
    "connection refused",
    "etimedout",
    "connect econnrefused",
]


# --- Pattern matching helpers ---


def _extract_log_texts(signals: list[Signal]) -> list[str]:
    """Extract all text strings from log-type signals."""
    texts: list[str] = []
    for signal in signals:
        if signal.kind == "logs" and isinstance(signal.data, list):
            for entry in signal.data:
                if isinstance(entry, dict) and "text" in entry:
                    texts.append(entry["text"])
                elif isinstance(entry, str):
                    texts.append(entry)
    return texts


def _extract_probe_data(signals: list[Signal]) -> dict | None:
    """Extract probe result dict from signals."""
    for signal in signals:
        if signal.source == "external_probe" and isinstance(signal.data, dict):
            return signal.data
    return None


def _has_oom_pattern(log_texts: list[str]) -> bool:
    """Check if any log line matches OOM patterns."""
    return any(
        any(pattern in text.lower() for pattern in _OOM_PATTERNS)
        for text in log_texts
    )


def _has_postgres_fatal_pattern(log_texts: list[str]) -> bool:
    """Check if any log line matches postgres FATAL/PANIC patterns."""
    return any(
        any(pattern in text.lower() for pattern in ["fatal", "panic"])
        for text in log_texts
    )


def _has_econnrefused_pattern(log_texts: list[str]) -> bool:
    """Check if any log line matches ECONNREFUSED patterns."""
    return any(
        any(pattern in text.lower() for pattern in _ECONNREFUSED_PATTERNS)
        for text in log_texts
    )


def _has_connection_refused_probe(probe_data: dict | None) -> bool:
    """Check if probe data indicates connection refused."""
    if not probe_data:
        return False
    for key, value in probe_data.items():
        if "error" in key and isinstance(value, str):
            if "refused" in value.lower() or "econnrefused" in value.lower():
                return True
    # Also check *_ok fields being False with tcp specifically
    if probe_data.get("tcp_ok") is False:
        return True
    return False


def _find_matching_lines(log_texts: list[str], patterns: list[str]) -> list[str]:
    """Find log lines matching any of the given patterns."""
    evidence: list[str] = []
    for text in log_texts:
        text_lower = text.lower()
        if any(pattern in text_lower for pattern in patterns):
            # Truncate long lines for evidence
            ref = text[:200] if len(text) > 200 else text
            evidence.append(f"log:{ref}")
    return evidence


def _unknown_fallback(
    incident: Incident, log_texts: list[str]
) -> tuple[str, str, list[str]]:
    """Generic fallback when no specific pattern matches."""
    kind_descriptions = {
        "cpu": "High CPU utilization sustained",
        "mem": "Memory pressure detected",
        "pg_fatal": "Postgres error detected",
        "n8n_error": "n8n workflow error or restart detected",
        "external_unreachable": "External service unreachable",
    }
    description = kind_descriptions.get(incident.kind, f"Incident kind={incident.kind}")

    return (
        f"{description} — no specific root-cause pattern matched in available logs",
        f"Review recent changes and logs for {incident.kind} incidents. "
        f"Check system resources and service health.",
        [],
    )
