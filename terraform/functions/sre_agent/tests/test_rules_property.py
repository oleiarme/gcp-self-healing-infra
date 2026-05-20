"""Property-based tests for rule_based_diagnose — confidence is always low.

**Validates: Requirements 6.5**

Property 7: Rule-based diagnosis confidence is low — rule_based_diagnose(incident, signals)
always returns a Diagnosis with confidence="low" and model="rule-based-v1", regardless of
incident kind or signal combinations.
"""

from datetime import datetime, timezone

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from sre_agent.models import Diagnosis, Incident, Signal
from sre_agent.rules import rule_based_diagnose


# ─── Strategies ───────────────────────────────────────────────────────────────

# All valid incident kinds from the model
_INCIDENT_KINDS = ["cpu", "mem", "pg_fatal", "n8n_error", "external_unreachable"]
_SEVERITIES = ["warning", "critical"]

# Generate incident kind
_incident_kind_st = st.sampled_from(_INCIDENT_KINDS)
_severity_st = st.sampled_from(_SEVERITIES)

# Generate realistic incident IDs
_incident_id_st = st.from_regex(r"inc-[a-z0-9]{4,12}", fullmatch=True)

# Generate resource dicts
_resource_st = st.one_of(
    st.fixed_dictionaries({"vm": st.from_regex(r"[a-z][a-z0-9\-]{3,15}", fullmatch=True)}),
    st.fixed_dictionaries({"public_host": st.from_regex(r"[a-z][a-z0-9\-]{3,10}\.[a-z]{2,4}", fullmatch=True)}),
    st.fixed_dictionaries({
        "vm": st.from_regex(r"[a-z][a-z0-9\-]{3,15}", fullmatch=True),
        "public_host": st.from_regex(r"[a-z][a-z0-9\-]{3,10}\.[a-z]{2,4}", fullmatch=True),
    }),
)

# Generate started_at timestamps (within a reasonable range)
_started_at_st = st.datetimes(
    min_value=datetime(2024, 1, 1),
    max_value=datetime(2027, 12, 31),
    timezones=st.just(timezone.utc),
)

# Generate Incident objects
_incident_st = st.builds(
    Incident,
    id=_incident_id_st,
    kind=_incident_kind_st,
    severity=_severity_st,
    started_at=_started_at_st,
    resource=_resource_st,
    raw_payload=st.just({"incident": {"incident_id": "test"}}),
    source=st.just("cloud-monitoring"),
)

# ─── Signal strategies ────────────────────────────────────────────────────────

# Log text lines — mix of normal and error-like content
_log_texts = st.sampled_from([
    "INFO: workflow completed successfully",
    "Out of memory: Killed process 1234 (n8n)",
    "FATAL: password authentication failed for user",
    "PANIC: could not write to file",
    "Error: connect ECONNREFUSED 127.0.0.1:5432",
    "ETIMEDOUT connecting to postgres",
    "n8n workflow execution failed",
    "DEBUG: processing request",
    "WARNING: high memory usage detected",
    "cannot allocate memory",
    "deadlock detected",
    "connection refused",
    "",
])

# Generate log signal data (list of dicts with text field)
_log_data_st = st.lists(
    st.fixed_dictionaries({
        "timestamp": _started_at_st.map(lambda dt: dt.isoformat()),
        "text": _log_texts,
        "container": st.sampled_from(["n8n", "postgres", "cloudflared"]),
    }),
    min_size=0,
    max_size=10,
)

# Log signals
_log_signal_st = st.builds(
    Signal,
    kind=st.just("logs"),
    source=st.sampled_from(["n8n_logs", "pg_logs", "cf_logs"]),
    data=_log_data_st,
)

# Probe result signals
_probe_data_st = st.fixed_dictionaries({
    "dns_ok": st.booleans(),
    "dns_error": st.one_of(st.none(), st.just("NXDOMAIN"), st.just("timeout")),
    "tcp_ok": st.booleans(),
    "tcp_error": st.one_of(st.none(), st.just("Connection refused"), st.just("timeout")),
    "https_root_ok": st.booleans(),
    "https_root_error": st.one_of(st.none(), st.just("SSL error"), st.just("timeout")),
    "https_deep_ok": st.booleans(),
    "https_deep_error": st.one_of(st.none(), st.just("503"), st.just("timeout")),
})

_probe_signal_st = st.builds(
    Signal,
    kind=st.just("probe"),
    source=st.just("external_probe"),
    data=_probe_data_st,
)

# Metric signals
_metric_data_st = st.lists(
    st.fixed_dictionaries({
        "timestamp": _started_at_st.map(lambda dt: dt.isoformat()),
        "value": st.floats(min_value=0.0, max_value=1.0),
    }),
    min_size=0,
    max_size=5,
)

_metric_signal_st = st.builds(
    Signal,
    kind=st.just("metrics"),
    source=st.just("cpu_metric"),
    data=_metric_data_st,
)

# Combined signal list: mix of logs, probes, and metrics (or empty)
_signals_st = st.lists(
    st.one_of(_log_signal_st, _probe_signal_st, _metric_signal_st),
    min_size=0,
    max_size=5,
)


# ─── Property 7 Test ─────────────────────────────────────────────────────────


@pytest.mark.property
class TestRuleBasedDiagnosisConfidenceLow:
    """Property 7: Rule-based diagnosis confidence is low.

    For any incident kind and any combination of signals,
    rule_based_diagnose always returns:
      - confidence == "low"
      - model == "rule-based-v1"

    **Validates: Requirements 6.5**
    """

    @given(incident=_incident_st, signals=_signals_st)
    @settings(max_examples=300, deadline=None)
    def test_confidence_always_low(self, incident: Incident, signals: list[Signal]):
        """**Validates: Requirements 6.5**

        rule_based_diagnose must always return confidence="low" regardless
        of incident kind, severity, or signal content.
        """
        diag = rule_based_diagnose(incident, signals)

        assert diag.confidence == "low", (
            f"Rule-based diagnosis confidence is not 'low'!\n"
            f"  incident.kind:    {incident.kind}\n"
            f"  incident.severity:{incident.severity}\n"
            f"  signals count:    {len(signals)}\n"
            f"  diag.confidence:  {diag.confidence!r}\n"
            f"  diag.model:       {diag.model!r}"
        )

    @given(incident=_incident_st, signals=_signals_st)
    @settings(max_examples=300, deadline=None)
    def test_model_always_rule_based_v1(self, incident: Incident, signals: list[Signal]):
        """**Validates: Requirements 6.5**

        rule_based_diagnose must always return model="rule-based-v1" regardless
        of incident kind, severity, or signal content.
        """
        diag = rule_based_diagnose(incident, signals)

        assert diag.model == "rule-based-v1", (
            f"Rule-based diagnosis model is not 'rule-based-v1'!\n"
            f"  incident.kind:    {incident.kind}\n"
            f"  incident.severity:{incident.severity}\n"
            f"  signals count:    {len(signals)}\n"
            f"  diag.model:       {diag.model!r}"
        )

    @given(incident=_incident_st, signals=_signals_st)
    @settings(max_examples=300, deadline=None)
    def test_returns_valid_diagnosis(self, incident: Incident, signals: list[Signal]):
        """**Validates: Requirements 6.5**

        rule_based_diagnose must always return a valid Diagnosis object with
        non-empty hypothesis and suggested_fix, zero tokens, and zero cost.
        """
        diag = rule_based_diagnose(incident, signals)

        assert isinstance(diag, Diagnosis), (
            f"Expected Diagnosis, got {type(diag).__name__}"
        )
        assert diag.hypothesis, "hypothesis must be non-empty"
        assert diag.suggested_fix, "suggested_fix must be non-empty"
        assert diag.tokens_in == 0, f"tokens_in must be 0, got {diag.tokens_in}"
        assert diag.tokens_out == 0, f"tokens_out must be 0, got {diag.tokens_out}"
        assert diag.cost_usd == 0.0, f"cost_usd must be 0.0, got {diag.cost_usd}"
