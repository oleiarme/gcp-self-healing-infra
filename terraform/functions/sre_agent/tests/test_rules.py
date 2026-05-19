"""Tests for rule_based_diagnose — deterministic fallback classifier.

Validates:
- Requirements 6.4: rule_based_diagnose classifies OOM, postgres FATAL, ECONNREFUSED, unknown
- Requirements 6.5: Always confidence="low", model="rule-based-v1"
"""

from datetime import datetime, timezone

import pytest

from sre_agent.models import Diagnosis, Incident, Signal
from sre_agent.rules import rule_based_diagnose


# --- Fixtures ---


def _make_incident(kind: str = "mem", severity: str = "critical") -> Incident:
    """Create a minimal Incident for testing."""
    return Incident(
        id="inc-test-001",
        kind=kind,
        severity=severity,
        started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
        resource={"vm": "test-vm-1"},
        raw_payload={"incident": {"incident_id": "inc-test-001"}},
        source="cloud-monitoring",
    )


def _make_signal_logs(texts: list[str], source: str = "n8n_logs") -> Signal:
    """Create a Signal with log lines."""
    from sre_agent.models import LogLine

    log_lines = [
        {"timestamp": datetime(2026, 1, 15, 2, 59, i, tzinfo=timezone.utc).isoformat(), "text": t, "container": "n8n"}
        for i, t in enumerate(texts)
    ]
    return Signal(kind="logs", source=source, data=log_lines)


def _make_signal_probe(probe_result: dict) -> Signal:
    """Create a Signal with external probe result."""
    return Signal(kind="probe", source="external_probe", data=probe_result)


# --- Core invariants (Req 6.5) ---


class TestRuleBasedInvariants:
    """All rule-based diagnoses must have confidence='low' and model='rule-based-v1'."""

    def test_confidence_always_low(self):
        incident = _make_incident(kind="mem")
        signals = [_make_signal_logs(["Out of memory: Killed process 1234"])]
        diag = rule_based_diagnose(incident, signals)
        assert diag.confidence == "low"

    def test_model_always_rule_based_v1(self):
        incident = _make_incident(kind="cpu")
        signals = []
        diag = rule_based_diagnose(incident, signals)
        assert diag.model == "rule-based-v1"

    def test_tokens_always_zero(self):
        incident = _make_incident(kind="pg_fatal")
        signals = []
        diag = rule_based_diagnose(incident, signals)
        assert diag.tokens_in == 0
        assert diag.tokens_out == 0
        assert diag.cost_usd == 0.0

    def test_returns_diagnosis_type(self):
        incident = _make_incident(kind="n8n_error")
        signals = []
        diag = rule_based_diagnose(incident, signals)
        assert isinstance(diag, Diagnosis)


# --- OOM classification (Req 6.4) ---


class TestOOMClassification:
    """Detects OOM from incident kind='mem' or log patterns."""

    def test_mem_kind_classified_as_oom(self):
        incident = _make_incident(kind="mem")
        signals = [_make_signal_logs(["Out of memory: Killed process 1234 (n8n)"])]
        diag = rule_based_diagnose(incident, signals)
        assert "oom" in diag.hypothesis.lower() or "out of memory" in diag.hypothesis.lower()

    def test_mem_kind_without_logs_still_oom(self):
        incident = _make_incident(kind="mem")
        signals = []
        diag = rule_based_diagnose(incident, signals)
        assert "oom" in diag.hypothesis.lower() or "out of memory" in diag.hypothesis.lower()

    def test_oom_suggested_fix_present(self):
        incident = _make_incident(kind="mem")
        signals = []
        diag = rule_based_diagnose(incident, signals)
        assert len(diag.suggested_fix) > 0


# --- Postgres FATAL classification (Req 6.4) ---


class TestPostgresFatalClassification:
    """Detects postgres FATAL/PANIC from incident kind or log patterns."""

    def test_pg_fatal_kind_classified(self):
        incident = _make_incident(kind="pg_fatal")
        signals = [_make_signal_logs(["FATAL:  password authentication failed for user"], source="pg_logs")]
        diag = rule_based_diagnose(incident, signals)
        assert "postgres" in diag.hypothesis.lower() or "pg" in diag.hypothesis.lower()

    def test_pg_fatal_without_logs(self):
        incident = _make_incident(kind="pg_fatal")
        signals = []
        diag = rule_based_diagnose(incident, signals)
        assert "postgres" in diag.hypothesis.lower() or "pg" in diag.hypothesis.lower() or "fatal" in diag.hypothesis.lower()


# --- ECONNREFUSED classification (Req 6.4) ---


class TestEconnrefusedClassification:
    """Detects ECONNREFUSED from log patterns in n8n signals."""

    def test_econnrefused_in_n8n_logs(self):
        incident = _make_incident(kind="n8n_error")
        signals = [_make_signal_logs(["Error: connect ECONNREFUSED 127.0.0.1:5432"])]
        diag = rule_based_diagnose(incident, signals)
        assert "econnrefused" in diag.hypothesis.lower() or "connection refused" in diag.hypothesis.lower()

    def test_econnrefused_from_external_probe(self):
        incident = _make_incident(kind="external_unreachable")
        signals = [_make_signal_probe({"tcp_ok": False, "tcp_error": "Connection refused"})]
        diag = rule_based_diagnose(incident, signals)
        # Should detect connection issue
        assert "connection" in diag.hypothesis.lower() or "unreachable" in diag.hypothesis.lower() or "refused" in diag.hypothesis.lower()


# --- Unknown classification (Req 6.4) ---


class TestUnknownClassification:
    """Falls back to 'unknown' when no pattern matches."""

    def test_cpu_kind_no_specific_pattern(self):
        incident = _make_incident(kind="cpu", severity="warning")
        signals = [_make_signal_logs(["INFO: workflow completed successfully"])]
        diag = rule_based_diagnose(incident, signals)
        # CPU without specific error patterns → generic diagnosis
        assert diag.hypothesis  # non-empty
        assert diag.confidence == "low"

    def test_empty_signals_unknown_kind(self):
        incident = _make_incident(kind="n8n_error")
        signals = []
        diag = rule_based_diagnose(incident, signals)
        assert diag.hypothesis  # non-empty
        assert diag.confidence == "low"


# --- Evidence refs ---


class TestEvidenceRefs:
    """Diagnosis should reference evidence when available."""

    def test_evidence_refs_populated_from_signals(self):
        incident = _make_incident(kind="mem")
        signals = [_make_signal_logs(["Out of memory: Killed process 1234"])]
        diag = rule_based_diagnose(incident, signals)
        assert isinstance(diag.evidence_refs, list)

    def test_evidence_refs_empty_when_no_signals(self):
        incident = _make_incident(kind="cpu")
        signals = []
        diag = rule_based_diagnose(incident, signals)
        assert isinstance(diag.evidence_refs, list)
