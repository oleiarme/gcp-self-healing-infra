"""End-to-end integration tests for sre_agent(cloud_event).

Validates: Requirements 12.4

Full cycle integration test:
  Pub/Sub message (base64 encoded alert payload) → parse → context (mocked)
  → LLM (mocked) → Telegram (mocked) → Firestore (mocked) → verify full chain.

Tests cover:
  - Happy path: complete processing cycle with all layers
  - Dedup path: duplicate incident returns early
  - Suppression path: live migration / bootstrap grace
  - Budget exhausted path: rule-based fallback with prefix
  - LLM failure path: rule-based fallback with [llm down: ...] prefix
"""

import base64
import json
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

from sre_agent.models import Diagnosis, Incident, Signal


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

ALERT_PAYLOAD = {
    "incident": {
        "incident_id": "inc-e2e-001",
        "policy_name": "vm_cpu_high",
        "started_at": "2026-01-15T03:00:00Z",
        "resource_name": "projects/my-proj/zones/us-central1-a/instances/n8n-prod-abc1",
    }
}


def _b64_cloud_event(payload: dict) -> MagicMock:
    """Build a mock CloudEvent with Pub/Sub base64-encoded message."""
    encoded = base64.b64encode(json.dumps(payload).encode()).decode()
    event = MagicMock()
    event.data = {"message": {"data": encoded}}
    return event


def _make_diagnosis(prefix: str = "") -> Diagnosis:
    """Build a minimal Diagnosis for testing."""
    return Diagnosis(
        hypothesis=f"{prefix}High CPU utilization from n8n workflow loop",
        evidence_refs=["log:cpu at 95%", "log:n8n workflow X running"],
        confidence="medium",
        suggested_fix="Disable workflow X or add concurrency limit",
        suggested_command="docker exec n8n n8n-cli workflow:disable --id=42",
        model="gemini-2.0-flash",
        tokens_in=1200,
        tokens_out=350,
        cost_usd=0.0012,
        created_at=datetime(2026, 1, 15, 3, 0, 45, tzinfo=timezone.utc),
    )


def _make_signals() -> list[Signal]:
    """Build sample signals for context gathering."""
    return [
        Signal(kind="n8n_logs", source="n8n_logs", data=["ERROR: workflow failed"]),
        Signal(kind="cpu_metric", source="cpu_metric", data=[{"ts": "2026-01-15T02:58:00Z", "value": 0.92}]),
    ]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.integration
class TestE2EHappyPath:
    """Full cycle: Pub/Sub → parse → context → LLM → Telegram → Firestore."""

    def test_full_cycle_returns_ok(self):
        """Complete e2e flow with base64 Pub/Sub message returns 'ok'."""
        cloud_event = _b64_cloud_event(ALERT_PAYLOAD)
        signals = _make_signals()
        diagnosis = _make_diagnosis()

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen") as mock_mark_seen, \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=7200), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("corr-e2e-001", False)), \
             patch("sre_agent.main.gather_context", return_value=(signals, {"partial": False})) as mock_gather, \
             patch("sre_agent.main.redact_signals", return_value=signals) as mock_redact, \
             patch("sre_agent.main.truncate_context", return_value=signals) as mock_truncate, \
             patch("sre_agent.main.today_cost_usd", return_value=0.50), \
             patch("sre_agent.main.analyze_with_llm", return_value=diagnosis) as mock_llm, \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis") as mock_persist:

            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240

            from sre_agent.main import sre_agent

            result = sre_agent(cloud_event)

            # Verify return value
            assert result == "ok"

            # Verify incident was marked as seen
            mock_mark_seen.assert_called_once_with("inc-e2e-001")

            # Verify context was gathered
            mock_gather.assert_called_once()
            gather_args = mock_gather.call_args[0]
            incident_arg = gather_args[0]
            assert incident_arg.id == "inc-e2e-001"
            assert incident_arg.kind == "cpu"
            assert incident_arg.severity == "warning"

            # Verify redaction was applied
            mock_redact.assert_called_once_with(signals)

            # Verify truncation was applied
            mock_truncate.assert_called_once_with(signals)

            # Verify LLM was called with correct incident and signals
            mock_llm.assert_called_once()
            llm_args = mock_llm.call_args[0]
            assert llm_args[0].id == "inc-e2e-001"
            assert llm_args[1] == signals

            # Verify Telegram notification sent
            mock_notify.assert_called_once()
            notify_args = mock_notify.call_args[0]
            assert notify_args[0].id == "inc-e2e-001"
            assert notify_args[1] == diagnosis
            assert notify_args[2] == "corr-e2e-001"

            # Verify diagnosis persisted
            mock_persist.assert_called_once_with(diagnosis, "corr-e2e-001")


@pytest.mark.integration
class TestE2EDedupPath:
    """Dedup path: duplicate incident returns 'duplicate' early."""

    def test_duplicate_incident_skips_all_processing(self):
        """When incident is a duplicate, no LLM/Telegram/Firestore calls happen."""
        cloud_event = _b64_cloud_event(ALERT_PAYLOAD)

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.is_duplicate", return_value=True), \
             patch("sre_agent.main.mark_seen") as mock_mark_seen, \
             patch("sre_agent.main.gather_context") as mock_gather, \
             patch("sre_agent.main.analyze_with_llm") as mock_llm, \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis") as mock_persist:

            mock_settings.enabled = True

            from sre_agent.main import sre_agent

            result = sre_agent(cloud_event)

            assert result == "duplicate"
            mock_mark_seen.assert_not_called()
            mock_gather.assert_not_called()
            mock_llm.assert_not_called()
            mock_notify.assert_not_called()
            mock_persist.assert_not_called()


@pytest.mark.integration
class TestE2ESuppressionPath:
    """Suppression path: live migration and bootstrap grace."""

    def test_live_migration_suppresses_with_brief_notify(self):
        """Live migration suppresses LLM but sends brief Telegram notification."""
        cloud_event = _b64_cloud_event(ALERT_PAYLOAD)

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=True), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped") as mock_skip, \
             patch("sre_agent.main.analyze_with_llm") as mock_llm, \
             patch("sre_agent.main.notify_telegram") as mock_notify:

            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800

            from sre_agent.main import sre_agent

            result = sre_agent(cloud_event)

            assert result == "suppressed:live_migration"
            mock_brief.assert_called_once()
            mock_skip.assert_called_once()
            mock_llm.assert_not_called()
            mock_notify.assert_not_called()

    def test_bootstrap_grace_suppresses_eligible_kind(self):
        """Bootstrap grace suppresses external_unreachable when VM is young."""
        payload = {
            "incident": {
                "incident_id": "inc-e2e-boot-001",
                "policy_name": "external_unreachable",
                "started_at": "2026-01-15T03:00:00Z",
                "resource_name": "projects/p/zones/z/instances/n8n-prod-abc1",
            }
        }
        cloud_event = _b64_cloud_event(payload)

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=300), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped") as mock_skip, \
             patch("sre_agent.main.analyze_with_llm") as mock_llm:

            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800

            from sre_agent.main import sre_agent

            result = sre_agent(cloud_event)

            assert result == "suppressed:bootstrap_grace"
            mock_brief.assert_called_once()
            mock_skip.assert_called_once()
            mock_llm.assert_not_called()


@pytest.mark.integration
class TestE2EBudgetExhaustedPath:
    """Budget exhausted path: rule-based fallback with [budget exhausted] prefix."""

    def test_budget_exhausted_uses_rule_based_fallback(self):
        """When daily budget is exceeded, LLM is skipped and rule-based is used."""
        cloud_event = _b64_cloud_event(ALERT_PAYLOAD)
        rule_diagnosis = Diagnosis(
            hypothesis="CPU sustained above threshold",
            evidence_refs=[],
            confidence="low",
            suggested_fix="Check running processes",
            model="rule-based-v1",
            tokens_in=0,
            tokens_out=0,
            cost_usd=0.0,
            created_at=datetime(2026, 1, 15, 3, 1, 0, tzinfo=timezone.utc),
        )

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=7200), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("corr-budget", False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=5.0), \
             patch("sre_agent.main.rule_based_diagnose", return_value=rule_diagnosis) as mock_rule, \
             patch("sre_agent.main.analyze_with_llm") as mock_llm, \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis") as mock_persist:

            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240

            from sre_agent.main import sre_agent

            result = sre_agent(cloud_event)

            assert result == "ok"
            mock_llm.assert_not_called()
            mock_rule.assert_called_once()

            # Verify [budget exhausted] prefix in diagnosis
            notify_args = mock_notify.call_args[0]
            diag = notify_args[1]
            assert diag.hypothesis.startswith("[budget exhausted]")

            # Verify persist was still called
            mock_persist.assert_called_once()


@pytest.mark.integration
class TestE2ELLMFailurePath:
    """LLM failure path: rule-based fallback with [llm down: reason] prefix."""

    def test_llm_exception_triggers_rule_based_fallback(self):
        """When LLM raises an exception, rule-based fallback is used."""
        cloud_event = _b64_cloud_event(ALERT_PAYLOAD)
        rule_diagnosis = Diagnosis(
            hypothesis="CPU sustained above threshold",
            evidence_refs=[],
            confidence="low",
            suggested_fix="Check running processes",
            model="rule-based-v1",
            tokens_in=0,
            tokens_out=0,
            cost_usd=0.0,
            created_at=datetime(2026, 1, 15, 3, 1, 0, tzinfo=timezone.utc),
        )

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=7200), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("corr-llm-fail", False)), \
             patch("sre_agent.main.gather_context", return_value=(_make_signals(), {})), \
             patch("sre_agent.main.redact_signals", return_value=_make_signals()), \
             patch("sre_agent.main.truncate_context", return_value=_make_signals()), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", side_effect=ConnectionError("Gemini API unreachable")), \
             patch("sre_agent.main.rule_based_diagnose", return_value=rule_diagnosis) as mock_rule, \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis") as mock_persist:

            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240

            from sre_agent.main import sre_agent

            result = sre_agent(cloud_event)

            assert result == "ok"
            mock_rule.assert_called_once()

            # Verify [llm down: ...] prefix in diagnosis
            notify_args = mock_notify.call_args[0]
            diag = notify_args[1]
            assert diag.hypothesis.startswith("[llm down:")
            assert "Gemini API unreachable" in diag.hypothesis

            # Verify Telegram and persist still called
            mock_notify.assert_called_once()
            mock_persist.assert_called_once()


@pytest.mark.integration
class TestE2ECorrelationPath:
    """Correlation path: co-signal joins existing window."""

    def test_correlated_signal_returns_early(self):
        """When signal correlates with existing window, returns 'correlated'."""
        cloud_event = _b64_cloud_event(ALERT_PAYLOAD)

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=7200), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("window-existing", True)), \
             patch("sre_agent.main.gather_context") as mock_gather, \
             patch("sre_agent.main.analyze_with_llm") as mock_llm, \
             patch("sre_agent.main.notify_telegram") as mock_notify:

            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800

            from sre_agent.main import sre_agent

            result = sre_agent(cloud_event)

            assert result == "correlated"
            mock_gather.assert_not_called()
            mock_llm.assert_not_called()
            mock_notify.assert_not_called()
