"""Property-based test: budget enforcement — LLM not called when budget exhausted.

**Validates: Requirements 4.2**
**Property 5: Token budget enforced**

When today_cost_usd() returns a value >= LLM_BUDGET_USD_PER_DAY,
the agent MUST NOT call LLM and MUST use rule-based fallback with
a [budget exhausted] prefix in the hypothesis.
"""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest
from hypothesis import given, settings as hyp_settings
from hypothesis import strategies as st

from sre_agent.models import Diagnosis, Incident, Signal


# --- Helpers ---


def _make_incident(kind: str = "cpu") -> Incident:
    """Build a minimal Incident for testing."""
    return Incident(
        id="inc-budget-test-001",
        kind=kind,
        severity="warning",
        started_at=datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc),
        resource={"vm": "n8n-prod-abc1"},
        raw_payload={"incident": {"incident_id": "inc-budget-test-001"}},
        source="cloud-monitoring",
    )


def _make_rule_based_diagnosis() -> Diagnosis:
    """Build a rule-based Diagnosis (before prefix is applied)."""
    return Diagnosis(
        hypothesis="High CPU utilization sustained",
        evidence_refs=[],
        confidence="low",
        suggested_fix="Check n8n workflows",
        suggested_command=None,
        model="rule-based-v1",
        tokens_in=0,
        tokens_out=0,
        cost_usd=0.0,
        created_at=datetime(2026, 6, 15, 10, 1, 0, tzinfo=timezone.utc),
    )


def _make_cloud_event() -> MagicMock:
    """Build a mock CloudEvent."""
    event = MagicMock()
    event.data = {
        "incident": {
            "incident_id": "inc-budget-test-001",
            "policy_name": "vm_cpu_high",
            "started_at": "2026-06-15T10:00:00Z",
            "resource_name": "projects/p/zones/z/instances/n8n-prod-abc1",
        }
    }
    return event


# --- Property test ---


class TestBudgetEnforcement:
    """Property 5: Token budget enforced.

    **Validates: Requirements 4.2**

    For any cost value >= budget, LLM must not be called and rule-based
    fallback with [budget exhausted] prefix must be used.
    """

    @given(
        cost_usd=st.floats(min_value=2.0, max_value=1000.0, allow_nan=False, allow_infinity=False),
        budget=st.floats(min_value=0.01, max_value=100.0, allow_nan=False, allow_infinity=False),
    )
    @hyp_settings(max_examples=50, deadline=None)
    def test_llm_not_called_when_budget_exhausted(self, cost_usd: float, budget: float):
        """When today_cost_usd() >= budget, LLM is never called.

        **Validates: Requirements 4.2**

        Property: For all cost >= budget, analyze_with_llm is not invoked
        and the resulting diagnosis has [budget exhausted] prefix.
        """
        # Ensure cost >= budget for this property
        effective_cost = max(cost_usd, budget)

        incident = _make_incident()
        rule_diagnosis = _make_rule_based_diagnosis()

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("corr-001", False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=effective_cost), \
             patch("sre_agent.main.analyze_with_llm") as mock_llm, \
             patch("sre_agent.main.rule_based_diagnose", return_value=rule_diagnosis), \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = budget
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240

            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            # Property assertions:
            # 1. LLM must NOT be called
            mock_llm.assert_not_called()

            # 2. Result should be "ok" (processing completed via fallback)
            assert result == "ok"

            # 3. Diagnosis sent to Telegram must have [budget exhausted] prefix
            notify_call_args = mock_notify.call_args
            diag_arg = notify_call_args[0][1]
            assert diag_arg.hypothesis.startswith("[budget exhausted]"), (
                f"Expected [budget exhausted] prefix, got: {diag_arg.hypothesis!r}"
            )

    @given(
        cost_usd=st.floats(min_value=0.0, max_value=1.99, allow_nan=False, allow_infinity=False),
    )
    @hyp_settings(max_examples=50, deadline=None)
    def test_llm_called_when_budget_not_exhausted(self, cost_usd: float):
        """When today_cost_usd() < budget, LLM IS called (inverse property).

        **Validates: Requirements 4.2**

        Property: For all cost < budget (fixed at 2.0), analyze_with_llm
        is invoked and the diagnosis does NOT have [budget exhausted] prefix.
        """
        budget = 2.0
        # Ensure cost < budget
        effective_cost = min(cost_usd, budget - 0.01)

        incident = _make_incident()
        llm_diagnosis = Diagnosis(
            hypothesis="Root cause: n8n workflow loop consuming CPU",
            evidence_refs=["log:cpu spike at 95%"],
            confidence="medium",
            suggested_fix="Disable the looping workflow",
            suggested_command=None,
            model="gemini-1.5-flash-002",
            tokens_in=1000,
            tokens_out=200,
            cost_usd=0.05,
            created_at=datetime(2026, 6, 15, 10, 1, 0, tzinfo=timezone.utc),
        )

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("corr-001", False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=effective_cost), \
             patch("sre_agent.main.analyze_with_llm", return_value=llm_diagnosis) as mock_llm, \
             patch("sre_agent.main.rule_based_diagnose") as mock_rule, \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = budget
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240

            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            # Property assertions:
            # 1. LLM MUST be called
            mock_llm.assert_called_once()

            # 2. Rule-based fallback must NOT be called
            mock_rule.assert_not_called()

            # 3. Result should be "ok"
            assert result == "ok"

            # 4. Diagnosis must NOT have [budget exhausted] prefix
            notify_call_args = mock_notify.call_args
            diag_arg = notify_call_args[0][1]
            assert not diag_arg.hypothesis.startswith("[budget exhausted]"), (
                f"Unexpected [budget exhausted] prefix when cost < budget"
            )

    def test_exact_budget_boundary_triggers_fallback(self):
        """Edge case: cost == budget exactly triggers rule-based fallback.

        **Validates: Requirements 4.2**

        Requirement states: "больше или равна LLM_BUDGET_USD_PER_DAY" (>=).
        """
        budget = 2.0
        cost_at_boundary = 2.0  # Exactly equal

        incident = _make_incident()
        rule_diagnosis = _make_rule_based_diagnosis()

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("corr-001", False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=cost_at_boundary), \
             patch("sre_agent.main.analyze_with_llm") as mock_llm, \
             patch("sre_agent.main.rule_based_diagnose", return_value=rule_diagnosis), \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = budget
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240

            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            # LLM must NOT be called at exact boundary
            mock_llm.assert_not_called()
            assert result == "ok"

            # Diagnosis must have [budget exhausted] prefix
            notify_call_args = mock_notify.call_args
            diag_arg = notify_call_args[0][1]
            assert diag_arg.hypothesis.startswith("[budget exhausted]")
