"""Unit tests for main.py — sre_agent(cloud_event) entry-point.

Validates: Requirements 1.7, 4.1–4.4, 7.2, 7.3, 9.2–9.7, 10.1–10.3

Tests cover:
  - Kill-switch: returns "disabled" when SRE_AGENT_ENABLED=false
  - Bad payload: returns "bad_payload" when parse_alert returns None
  - Structured log event=invocation with incident.id and kind
  - Dedup: returns "duplicate" when is_duplicate returns True
  - Suppression: returns "suppressed" for live migration / bootstrap grace
  - Correlation: returns "correlated" when incident joins existing window
  - Budget exhausted: uses rule_based_diagnose with [budget exhausted] prefix
  - LLM failure: uses rule_based_diagnose with [llm down: reason] prefix
  - Happy path: gather → redact → truncate → LLM → notify → persist → "ok"
  - Processing timeout: partial fallback on timeout
  - Pub/Sub base64 payload extraction
"""

import base64
import json
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch, PropertyMock

import pytest

from sre_agent.models import Diagnosis, Incident, Signal


# --- Helpers ---


def _make_incident(
    incident_id: str = "inc-test-001",
    kind: str = "cpu",
    severity: str = "warning",
) -> Incident:
    """Build a minimal Incident for testing."""
    return Incident(
        id=incident_id,
        kind=kind,
        severity=severity,
        started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
        resource={"vm": "n8n-prod-abc1"},
        raw_payload={"incident": {"incident_id": incident_id}},
        source="cloud-monitoring",
    )


def _make_diagnosis(prefix: str = "") -> Diagnosis:
    """Build a minimal Diagnosis for testing."""
    return Diagnosis(
        hypothesis=f"{prefix}High CPU utilization detected",
        evidence_refs=["log:cpu at 95%"],
        confidence="low",
        suggested_fix="Check n8n workflows",
        suggested_command=None,
        model="rule-based-v1",
        tokens_in=0,
        tokens_out=0,
        cost_usd=0.0,
        created_at=datetime(2026, 1, 15, 3, 1, 0, tzinfo=timezone.utc),
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


# --- Tests ---


class TestKillSwitch:
    """Requirement 7.2: Kill-switch returns 'disabled' immediately."""

    def test_returns_disabled_when_sre_agent_enabled_false(self):
        """When SRE_AGENT_ENABLED=false, return 'disabled' with no side effects."""
        with patch("sre_agent.main.settings") as mock_settings:
            mock_settings.enabled = False
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "disabled"

    def test_proceeds_when_enabled(self):
        """When SRE_AGENT_ENABLED=true, processing continues past kill-switch."""
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=None):
            mock_settings.enabled = True
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "bad_payload"


class TestBadPayload:
    """Requirement 1.7: Returns 'bad_payload' when parse_alert returns None."""

    def test_returns_bad_payload_when_parse_alert_returns_none(self):
        """Invalid payload → 'bad_payload', no side effects."""
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=None):
            mock_settings.enabled = True
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event({"garbage": True}))
            assert result == "bad_payload"


class TestStructuredLog:
    """Requirement 7.3: Structured log event=invocation with incident.id and kind."""

    def test_logs_invocation_event(self):
        """After successful parse, logs event=invocation with incident.id and kind."""
        incident = _make_incident()
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=True), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.logger") as mock_logger:
            mock_settings.enabled = True
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())

            # Check that logger.info was called with event=invocation
            calls = mock_logger.info.call_args_list
            invocation_logged = any(
                "invocation" in str(call) or
                (call.kwargs.get("extra", {}).get("event") == "invocation"
                 if call.kwargs else False)
                for call in calls
            )
            assert invocation_logged, f"Expected event=invocation log, got: {calls}"


class TestDedup:
    """Requirement 4.1: Deduplication returns 'duplicate' for already-seen incidents."""

    def test_returns_duplicate_when_already_seen(self):
        """When is_duplicate returns True, return 'duplicate'."""
        incident = _make_incident()
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=True), \
             patch("sre_agent.main.mark_seen") as mock_mark:
            mock_settings.enabled = True
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "duplicate"
            # mark_seen should NOT be called for duplicates (only update last_seen_at)
            mock_mark.assert_not_called()

    def test_marks_seen_when_not_duplicate(self):
        """When not duplicate, mark_seen is called."""
        incident = _make_incident()
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen") as mock_mark, \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=(None, False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", return_value=_make_diagnosis()), \
             patch("sre_agent.main.notify_telegram"), \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())
            mock_mark.assert_called_once_with(incident.id)


class TestSuppression:
    """Requirements 9.2, 9.3: Suppression for Live Migration and bootstrap grace."""

    def test_returns_suppressed_for_live_migration(self):
        """When live migration detected in window, return 'suppressed:live_migration'."""
        incident = _make_incident()
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=True), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped") as mock_skip:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "suppressed:live_migration"
            mock_brief.assert_called_once()
            mock_skip.assert_called_once()

    def test_returns_suppressed_for_bootstrap_grace(self):
        """When instance age < bootstrap_grace_seconds for eligible kind, return 'suppressed:bootstrap_grace'."""
        incident = _make_incident(kind="external_unreachable")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=600), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped") as mock_skip:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "suppressed:bootstrap_grace"
            mock_brief.assert_called_once()
            mock_skip.assert_called_once()

    def test_bootstrap_grace_only_for_eligible_kinds(self):
        """Bootstrap grace suppression only applies to external_unreachable and n8n_error."""
        incident = _make_incident(kind="cpu")  # cpu is NOT eligible
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=600), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("corr-001", False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", return_value=_make_diagnosis()), \
             patch("sre_agent.main.notify_telegram"), \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            # cpu kind with young VM should NOT be suppressed
            result = sre_agent(_make_cloud_event())
            assert result == "ok"

    def test_not_suppressed_when_instance_old_enough(self):
        """When instance age > bootstrap_grace_seconds, not suppressed."""
        incident = _make_incident(kind="n8n_error")  # eligible kind
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=(None, False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", return_value=_make_diagnosis()), \
             patch("sre_agent.main.notify_telegram"), \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "ok"


class TestCorrelation:
    """Requirement 9.1: Correlation returns 'correlated' for co-signals."""

    def test_returns_correlated_when_joined_existing_window(self):
        """When find_or_create_incident_window returns correlated=True, return 'correlated'."""
        incident = _make_incident()
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("window-123", True)):
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "correlated"


class TestBudgetExhausted:
    """Requirement 4.4: Budget exhausted uses rule-based with prefix."""

    def test_uses_rule_based_with_budget_exhausted_prefix(self):
        """When today_cost >= budget, use rule_based_diagnose with [budget exhausted] prefix."""
        incident = _make_incident()
        diagnosis = _make_diagnosis()
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
             patch("sre_agent.main.today_cost_usd", return_value=2.50), \
             patch("sre_agent.main.rule_based_diagnose", return_value=diagnosis) as mock_rule, \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis") as mock_persist:
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "ok"
            mock_rule.assert_called_once()
            # Verify the diagnosis passed to notify has [budget exhausted] prefix
            notify_call_args = mock_notify.call_args
            diag_arg = notify_call_args[0][1] if notify_call_args[0] else notify_call_args[1].get("diagnosis")
            assert diag_arg.hypothesis.startswith("[budget exhausted]")


class TestLLMFailure:
    """Requirement 6.4: LLM failure uses rule-based with [llm down: reason] prefix."""

    def test_uses_rule_based_with_llm_down_prefix_on_exception(self):
        """When analyze_with_llm raises, use rule_based_diagnose with [llm down: reason] prefix."""
        incident = _make_incident()
        diagnosis = _make_diagnosis()
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
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", side_effect=Exception("API timeout")), \
             patch("sre_agent.main.rule_based_diagnose", return_value=diagnosis) as mock_rule, \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis") as mock_persist:
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "ok"
            mock_rule.assert_called_once()
            # Verify the diagnosis passed to notify has [llm down: ...] prefix
            notify_call_args = mock_notify.call_args
            diag_arg = notify_call_args[0][1] if notify_call_args[0] else notify_call_args[1].get("diagnosis")
            assert diag_arg.hypothesis.startswith("[llm down:")


class TestHappyPath:
    """Full happy path: gather → redact → truncate → LLM → notify → persist → 'ok'."""

    def test_full_happy_path_returns_ok(self):
        """Complete processing cycle returns 'ok'."""
        incident = _make_incident()
        diagnosis = _make_diagnosis()
        signals = [Signal(kind="n8n_logs", source="n8n_logs", data=["line1"])]
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("corr-001", False)), \
             patch("sre_agent.main.gather_context", return_value=(signals, {})), \
             patch("sre_agent.main.redact_signals", return_value=signals), \
             patch("sre_agent.main.truncate_context", return_value=signals), \
             patch("sre_agent.main.today_cost_usd", return_value=0.5), \
             patch("sre_agent.main.analyze_with_llm", return_value=diagnosis), \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis") as mock_persist:
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "ok"
            mock_notify.assert_called_once_with(incident, diagnosis, "corr-001")
            mock_persist.assert_called_once_with(diagnosis, "corr-001")

    def test_notify_and_persist_called_with_correct_args(self):
        """Notify and persist receive the correct incident, diagnosis, correlation_id."""
        incident = _make_incident()
        diagnosis = _make_diagnosis()
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("window-xyz", False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", return_value=diagnosis), \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis") as mock_persist:
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())
            mock_notify.assert_called_once_with(incident, diagnosis, "window-xyz")
            mock_persist.assert_called_once_with(diagnosis, "window-xyz")


class TestProcessingTimeout:
    """Requirement 10.3: Processing timeout with partial fallback."""

    def test_timeout_returns_ok_with_timeout_prefix(self):
        """When processing exceeds timeout, use rule-based with [timeout] prefix."""
        import time

        incident = _make_incident()
        diagnosis = _make_diagnosis()

        def slow_gather(*args, **kwargs):
            time.sleep(2)  # Exceed the 0.1s timeout
            return ([], {})

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("corr-001", False)), \
             patch("sre_agent.main.gather_context", side_effect=slow_gather), \
             patch("sre_agent.main.rule_based_diagnose", return_value=diagnosis), \
             patch("sre_agent.main.notify_telegram") as mock_notify, \
             patch("sre_agent.main.persist_diagnosis") as mock_persist:
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 0.1  # Very short timeout

            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "ok"
            # Verify the diagnosis has [timeout] prefix
            notify_call_args = mock_notify.call_args
            diag_arg = notify_call_args[0][1]
            assert diag_arg.hypothesis.startswith("[timeout]")


class TestExtractPayload:
    """Test _extract_payload handles both direct dict and Pub/Sub envelope formats."""

    def test_direct_dict_payload_passed_through(self):
        """Direct dict payload (no Pub/Sub envelope) is returned as-is."""
        from sre_agent.main import _extract_payload

        payload = {"incident": {"incident_id": "inc-001", "policy_name": "vm_cpu_high"}}
        event = MagicMock()
        event.data = payload

        result = _extract_payload(event)
        assert result == payload

    def test_pubsub_envelope_base64_decoded(self):
        """Pub/Sub envelope with base64-encoded message.data is decoded."""
        from sre_agent.main import _extract_payload

        inner_payload = {"incident": {"incident_id": "inc-002", "policy_name": "vm_cpu_high"}}
        encoded = base64.b64encode(json.dumps(inner_payload).encode()).decode()

        event = MagicMock()
        event.data = {"message": {"data": encoded}}

        result = _extract_payload(event)
        assert result == inner_payload

    def test_pubsub_envelope_invalid_base64_returns_none(self):
        """Invalid base64 in Pub/Sub envelope returns None."""
        from sre_agent.main import _extract_payload

        event = MagicMock()
        event.data = {"message": {"data": "not-valid-base64!!!"}}

        result = _extract_payload(event)
        assert result is None

    def test_pubsub_envelope_invalid_json_returns_none(self):
        """Valid base64 but invalid JSON in Pub/Sub envelope returns None."""
        from sre_agent.main import _extract_payload

        encoded = base64.b64encode(b"not json at all").decode()
        event = MagicMock()
        event.data = {"message": {"data": encoded}}

        result = _extract_payload(event)
        assert result is None

    def test_pubsub_base64_payload_triggers_full_flow(self):
        """End-to-end: Pub/Sub base64 payload goes through full sre_agent flow."""
        inner_payload = {
            "incident": {
                "incident_id": "inc-pubsub-001",
                "policy_name": "vm_cpu_high",
                "started_at": "2026-01-15T03:00:00Z",
                "resource_name": "projects/p/zones/z/instances/n8n-prod-abc1",
            }
        }
        encoded = base64.b64encode(json.dumps(inner_payload).encode()).decode()

        event = MagicMock()
        event.data = {"message": {"data": encoded}}

        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.is_duplicate", return_value=True), \
             patch("sre_agent.main.mark_seen"):
            mock_settings.enabled = True
            from sre_agent.main import sre_agent

            result = sre_agent(event)
            # Should get past parse_alert (valid payload) and hit dedup
            assert result == "duplicate"


class TestMarkSeenCalledCorrectly:
    """Verify mark_seen is called with incident.id after dedup check passes."""

    def test_mark_seen_called_with_incident_id(self):
        """mark_seen receives the incident.id as argument."""
        incident = _make_incident(incident_id="inc-mark-test")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen") as mock_mark, \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=5000), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=("w-1", False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", return_value=_make_diagnosis()), \
             patch("sre_agent.main.notify_telegram"), \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())
            mock_mark.assert_called_once_with("inc-mark-test")


class TestLLMNotCalledWhenSuppressed:
    """Verify LLM is never invoked when incident is suppressed."""

    def test_llm_not_called_on_live_migration_suppression(self):
        """LLM should not be called when live migration suppresses the incident."""
        incident = _make_incident()
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=True), \
             patch("sre_agent.main.notify_telegram_brief"), \
             patch("sre_agent.main.persist_diagnosis_skipped"), \
             patch("sre_agent.main.analyze_with_llm") as mock_llm:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "suppressed:live_migration"
            mock_llm.assert_not_called()

    def test_llm_not_called_on_bootstrap_grace_suppression(self):
        """LLM should not be called when bootstrap grace suppresses the incident."""
        incident = _make_incident(kind="n8n_error")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=300), \
             patch("sre_agent.main.notify_telegram_brief"), \
             patch("sre_agent.main.persist_diagnosis_skipped"), \
             patch("sre_agent.main.analyze_with_llm") as mock_llm:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())
            assert result == "suppressed:bootstrap_grace"
            mock_llm.assert_not_called()
