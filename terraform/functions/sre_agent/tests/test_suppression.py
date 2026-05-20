"""Unit tests for suppression logic in main.py — Property 11 (P11).

**Validates: Requirements 9.2, 9.3**

Property 11: Suppression skips LLM during Live Migration / bootstrap grace.

Formally:
  (LiveMigration(vm, t±300s) ∨ age(vm) < BOOTSTRAP_GRACE_SECONDS)
    ⇒ ¬LLM.called ∧ outcome ∈ {"suppressed:live_migration", "suppressed:bootstrap_grace"}

Tests verify:
  1. When is_live_migration_in_window() returns True → LLM NOT called,
     brief notification IS sent, result is "suppressed:live_migration".
  2. When instance_age_seconds_cached() < bootstrap_grace_seconds (1800s)
     for eligible kinds (external_unreachable, n8n_error) → LLM NOT called,
     brief notification IS sent, result is "suppressed:bootstrap_grace".
"""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

from sre_agent.models import Incident


# --- Helpers ---


def _make_incident(
    incident_id: str = "inc-suppress-001",
    kind: str = "cpu",
    severity: str = "warning",
) -> Incident:
    """Build a minimal Incident for suppression testing."""
    return Incident(
        id=incident_id,
        kind=kind,
        severity=severity,
        started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
        resource={"vm": "n8n-prod-abc1"},
        raw_payload={"incident": {"incident_id": incident_id}},
        source="cloud-monitoring",
    )


def _make_cloud_event(payload: dict | None = None) -> MagicMock:
    """Build a mock CloudEvent with data attribute."""
    event = MagicMock()
    if payload is None:
        payload = {
            "incident": {
                "incident_id": "inc-suppress-001",
                "policy_name": "vm_cpu_high",
                "started_at": "2026-01-15T03:00:00Z",
                "resource_name": "projects/p/zones/z/instances/n8n-prod-abc1",
            }
        }
    event.data = payload
    return event


# --- Live Migration Suppression Tests ---


class TestLiveMigrationSuppression:
    """Requirement 9.2: Live Migration in ±300s window suppresses LLM call."""

    def test_llm_not_called_when_live_migration_detected(self):
        """When is_live_migration_in_window returns True, analyze_with_llm is NOT called."""
        incident = _make_incident(kind="cpu")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=True), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped"), \
             patch("sre_agent.main.analyze_with_llm") as mock_llm:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            assert result == "suppressed:live_migration"
            mock_llm.assert_not_called()

    def test_brief_notification_sent_on_live_migration(self):
        """When live migration suppresses, notify_telegram_brief IS called with reason='live_migration'."""
        incident = _make_incident(kind="external_unreachable")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=True), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped"):
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())

            mock_brief.assert_called_once_with(incident, "live_migration")

    def test_persist_skipped_on_live_migration(self):
        """When live migration suppresses, persist_diagnosis_skipped IS called."""
        incident = _make_incident(kind="n8n_error")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=True), \
             patch("sre_agent.main.notify_telegram_brief"), \
             patch("sre_agent.main.persist_diagnosis_skipped") as mock_skip:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())

            mock_skip.assert_called_once_with(incident, "live_migration")

    def test_gather_context_not_called_on_live_migration(self):
        """When live migration suppresses, gather_context is NOT called (no context collection)."""
        incident = _make_incident(kind="cpu")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=True), \
             patch("sre_agent.main.notify_telegram_brief"), \
             patch("sre_agent.main.persist_diagnosis_skipped"), \
             patch("sre_agent.main.gather_context") as mock_gather:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())

            mock_gather.assert_not_called()


# --- Bootstrap Grace Suppression Tests ---


class TestBootstrapGraceSuppression:
    """Requirement 9.3: Instance age < BOOTSTRAP_GRACE_SECONDS suppresses LLM for eligible kinds."""

    def test_llm_not_called_when_instance_young_external_unreachable(self):
        """external_unreachable with vm_age < 1800s → LLM NOT called."""
        incident = _make_incident(kind="external_unreachable")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=600), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped"), \
             patch("sre_agent.main.analyze_with_llm") as mock_llm:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            assert result == "suppressed:bootstrap_grace"
            mock_llm.assert_not_called()

    def test_llm_not_called_when_instance_young_n8n_error(self):
        """n8n_error with vm_age < 1800s → LLM NOT called."""
        incident = _make_incident(kind="n8n_error")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=120), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped"), \
             patch("sre_agent.main.analyze_with_llm") as mock_llm:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            assert result == "suppressed:bootstrap_grace"
            mock_llm.assert_not_called()

    def test_brief_notification_sent_with_vm_age(self):
        """When bootstrap grace suppresses, notify_telegram_brief IS called with vm_age."""
        incident = _make_incident(kind="external_unreachable")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=450), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped"):
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())

            mock_brief.assert_called_once_with(incident, "bootstrap_grace", vm_age=450)

    def test_persist_skipped_on_bootstrap_grace(self):
        """When bootstrap grace suppresses, persist_diagnosis_skipped IS called."""
        incident = _make_incident(kind="n8n_error")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=900), \
             patch("sre_agent.main.notify_telegram_brief"), \
             patch("sre_agent.main.persist_diagnosis_skipped") as mock_skip:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())

            mock_skip.assert_called_once_with(incident, "bootstrap_grace")

    def test_gather_context_not_called_on_bootstrap_grace(self):
        """When bootstrap grace suppresses, gather_context is NOT called."""
        incident = _make_incident(kind="external_unreachable")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=300), \
             patch("sre_agent.main.notify_telegram_brief"), \
             patch("sre_agent.main.persist_diagnosis_skipped"), \
             patch("sre_agent.main.gather_context") as mock_gather:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            sre_agent(_make_cloud_event())

            mock_gather.assert_not_called()

    def test_boundary_value_exactly_at_grace_threshold(self):
        """When vm_age == bootstrap_grace_seconds (1800), NOT suppressed (must be strictly less)."""
        incident = _make_incident(kind="n8n_error")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=1800), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=(None, False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", return_value=MagicMock()) as mock_llm, \
             patch("sre_agent.main.notify_telegram"), \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            # vm_age == 1800 is NOT < 1800, so should proceed to LLM
            assert result == "ok"
            mock_llm.assert_called_once()

    def test_boundary_value_just_below_grace_threshold(self):
        """When vm_age == 1799 (just below 1800), IS suppressed."""
        incident = _make_incident(kind="external_unreachable")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=1799), \
             patch("sre_agent.main.notify_telegram_brief") as mock_brief, \
             patch("sre_agent.main.persist_diagnosis_skipped"), \
             patch("sre_agent.main.analyze_with_llm") as mock_llm:
            mock_settings.enabled = True
            mock_settings.bootstrap_grace_seconds = 1800
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            assert result == "suppressed:bootstrap_grace"
            mock_llm.assert_not_called()
            mock_brief.assert_called_once()


# --- Ineligible Kinds (bootstrap grace does NOT apply) ---


class TestBootstrapGraceIneligibleKinds:
    """Requirement 9.6: pg_fatal and mem are NEVER suppressed by bootstrap grace."""

    @pytest.mark.parametrize("kind", ["cpu", "pg_fatal", "mem"])
    def test_ineligible_kinds_not_suppressed_by_bootstrap_grace(self, kind):
        """Kinds not in {external_unreachable, n8n_error} bypass bootstrap grace."""
        incident = _make_incident(kind=kind)
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=100), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=(None, False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", return_value=MagicMock()) as mock_llm, \
             patch("sre_agent.main.notify_telegram"), \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            # These kinds should NOT be suppressed even with young VM
            assert result == "ok"
            mock_llm.assert_called_once()


# --- instance_age_seconds_cached returns None ---


class TestBootstrapGraceWhenAgeUnknown:
    """When instance_age_seconds_cached returns None, bootstrap grace does NOT suppress."""

    def test_not_suppressed_when_age_is_none(self):
        """If Compute API fails (returns None), bootstrap grace is skipped."""
        incident = _make_incident(kind="external_unreachable")
        with patch("sre_agent.main.settings") as mock_settings, \
             patch("sre_agent.main.parse_alert", return_value=incident), \
             patch("sre_agent.main.is_duplicate", return_value=False), \
             patch("sre_agent.main.mark_seen"), \
             patch("sre_agent.main.is_live_migration_in_window", return_value=False), \
             patch("sre_agent.main.instance_age_seconds_cached", return_value=None), \
             patch("sre_agent.main.find_or_create_incident_window", return_value=(None, False)), \
             patch("sre_agent.main.gather_context", return_value=([], {})), \
             patch("sre_agent.main.redact_signals", return_value=[]), \
             patch("sre_agent.main.truncate_context", return_value=[]), \
             patch("sre_agent.main.today_cost_usd", return_value=0.0), \
             patch("sre_agent.main.analyze_with_llm", return_value=MagicMock()) as mock_llm, \
             patch("sre_agent.main.notify_telegram"), \
             patch("sre_agent.main.persist_diagnosis"):
            mock_settings.enabled = True
            mock_settings.llm_budget_usd_per_day = 2.0
            mock_settings.bootstrap_grace_seconds = 1800
            mock_settings.processing_timeout_seconds = 240
            from sre_agent.main import sre_agent

            result = sre_agent(_make_cloud_event())

            # None age → cannot determine if young → proceed to LLM
            assert result == "ok"
            mock_llm.assert_called_once()
