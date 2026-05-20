"""Property-based test for deduplication preventing repeated LLM calls.

**Validates: Requirements 4.1**

Property 4: Deduplication — for two invocations with the same incident.id,
LLM is called ≤ 1 time. When is_duplicate(incident_id) returns True (second
invocation with same ID), the LLM is NOT called again.

Tests the integration between store.is_duplicate() and the main flow in main.py.
"""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest
from hypothesis import given, settings as hyp_settings
from hypothesis import strategies as st

from sre_agent.models import Diagnosis, Incident


# --- Strategies ---

# Generate valid incident IDs (non-empty strings resembling real IDs)
_incident_id_strategy = st.text(
    alphabet=st.sampled_from("abcdefghijklmnopqrstuvwxyz0123456789-_"),
    min_size=1,
    max_size=50,
).map(lambda s: f"inc-{s}")

# Generate valid incident kinds
_kind_strategy = st.sampled_from(["cpu", "mem", "pg_fatal", "n8n_error", "external_unreachable"])

# Generate valid severities
_severity_strategy = st.sampled_from(["warning", "critical"])


# --- Helpers ---


def _make_incident(incident_id: str, kind: str = "cpu", severity: str = "warning") -> Incident:
    """Build a minimal Incident for testing."""
    return Incident(
        id=incident_id,
        kind=kind,
        severity=severity,
        started_at=datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc),
        resource={"vm": "n8n-prod-abc1"},
        raw_payload={"incident": {"incident_id": incident_id}},
        source="cloud-monitoring",
    )


def _make_diagnosis() -> Diagnosis:
    """Build a minimal Diagnosis for testing."""
    return Diagnosis(
        hypothesis="High CPU utilization detected",
        evidence_refs=["log:cpu at 95%"],
        confidence="low",
        suggested_fix="Check n8n workflows",
        suggested_command=None,
        model="rule-based-v1",
        tokens_in=0,
        tokens_out=0,
        cost_usd=0.0,
        created_at=datetime(2026, 6, 15, 10, 1, 0, tzinfo=timezone.utc),
    )


def _make_cloud_event(payload: dict | None = None) -> MagicMock:
    """Build a mock CloudEvent with data attribute."""
    event = MagicMock()
    if payload is None:
        payload = {
            "incident": {
                "incident_id": "inc-test-001",
                "policy_name": "vm_cpu_high",
                "started_at": "2026-01-15T03:00:00Z",
                "resource_name": "projects/p/zones/z/instances/n8n-prod-abc1",
            }
        }
    event.data = payload
    return event


# --- Property Test ---


@pytest.mark.property
class TestDeduplicationPreventsLLMCall:
    """Property 4: Deduplication — for two invocations with the same incident.id,
    LLM is called ≤ 1 time.

    **Validates: Requirements 4.1**
    """

    @given(
        incident_id=_incident_id_strategy,
        kind=_kind_strategy,
        severity=_severity_strategy,
    )
    @hyp_settings(max_examples=100, deadline=None)
    def test_duplicate_incident_does_not_call_llm(
        self, incident_id: str, kind: str, severity: str
    ):
        """**Validates: Requirements 4.1**

        When is_duplicate returns True for a given incident_id, the main flow
        returns 'duplicate' and analyze_with_llm is never called.
        """
        incident = _make_incident(incident_id, kind=kind, severity=severity)

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=True), \
             patch("sre_agent.main.mark_seen") as mock_mark, \
             patch("sre_agent.main.analyze_with_llm") as mock_llm:
            mock_settings.enabled = True

            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            # Dedup must short-circuit: return "duplicate"
            assert result == "duplicate"
            # LLM must NOT be called
            mock_llm.assert_not_called()
            # mark_seen must NOT be called (incident already seen)
            mock_mark.assert_not_called()

    @given(
        incident_id=_incident_id_strategy,
        kind=_kind_strategy,
    )
    @hyp_settings(max_examples=100, deadline=None)
    def test_first_invocation_calls_llm_second_does_not(
        self, incident_id: str, kind: str
    ):
        """**Validates: Requirements 4.1**

        Simulates two invocations with the same incident_id:
        - First invocation: is_duplicate=False → LLM is called (≤ 1 call)
        - Second invocation: is_duplicate=True → LLM is NOT called
        Total LLM calls across both invocations ≤ 1.
        """
        incident = _make_incident(incident_id, kind=kind)
        diagnosis = _make_diagnosis()

        llm_call_count = 0

        def counting_llm(*args, **kwargs):
            nonlocal llm_call_count
            llm_call_count += 1
            return diagnosis

        # First invocation: not a duplicate → full processing
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("w-1", False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", side_effect=counting_llm), \
             patch("sre_agent.main.notify_telegram"), \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240

            from sre_agent.main import sre_agent

            result1 = sre_agent(_make_cloud_event())
            assert result1 == "ok"

        # Second invocation: duplicate → short-circuit
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=True), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.analyze_with_llm", side_effect=counting_llm):
            mock_settings.enabled = True

            from sre_agent.main import sre_agent

            result2 = sre_agent(_make_cloud_event())
            assert result2 == "duplicate"

        # Property: LLM called ≤ 1 time across both invocations
        assert llm_call_count <= 1, (
            f"LLM was called {llm_call_count} times for incident_id={incident_id!r}, "
            f"expected ≤ 1 (dedup should prevent second call)"
        )
