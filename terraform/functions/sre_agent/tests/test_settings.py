"""Tests for settings.py — единый источник конфигурации через Pydantic BaseSettings.

Validates Requirements: 4.2, 7.2, 9.1, 9.2, 11.1, 11.4, 13.1, 13.2
"""

import os
from unittest.mock import patch

import pytest


class TestSettingsDefaults:
    """Settings loads with correct defaults when required env vars are set."""

    def _make_settings(self, **overrides):
        """Create a fresh Settings instance with minimal required env vars."""
        env = {
            "GCP_PROJECT_ID": "test-project",
            **overrides,
        }
        with patch.dict(os.environ, env, clear=False):
            from sre_agent.settings import Settings
            return Settings()

    def test_kill_switch_default_enabled(self):
        """Req 7.2: SRE_AGENT_ENABLED defaults to True."""
        s = self._make_settings()
        assert s.sre_agent_enabled is True

    def test_kill_switch_disabled_via_env(self):
        """Req 7.2: SRE_AGENT_ENABLED=false disables the agent."""
        s = self._make_settings(SRE_AGENT_ENABLED="false")
        assert s.sre_agent_enabled is False

    def test_enabled_property_mirrors_sre_agent_enabled(self):
        """settings.enabled is a convenience alias for sre_agent_enabled."""
        s = self._make_settings()
        assert s.enabled is True
        s2 = self._make_settings(SRE_AGENT_ENABLED="false")
        assert s2.enabled is False

    def test_bootstrap_grace_seconds_default(self):
        """Req 9.2: BOOTSTRAP_GRACE_SECONDS defaults to 1800."""
        s = self._make_settings()
        assert s.bootstrap_grace_seconds == 1800

    def test_live_migration_window_sec_default(self):
        """Req 9.2: LIVE_MIGRATION_WINDOW_SEC defaults to 300."""
        s = self._make_settings()
        assert s.live_migration_window_sec == 300

    def test_correlation_window_sec_default(self):
        """Req 9.1: CORRELATION_WINDOW_SEC defaults to 90."""
        s = self._make_settings()
        assert s.correlation_window_sec == 90

    def test_cross_kind_correlation_window_sec_default(self):
        """Req 9.1: CROSS_KIND_CORRELATION_WINDOW_SEC defaults to 180."""
        s = self._make_settings()
        assert s.cross_kind_correlation_window_sec == 180

    def test_llm_budget_usd_per_day_default(self):
        """Req 4.2: LLM_BUDGET_USD_PER_DAY defaults to 2.00."""
        s = self._make_settings()
        assert s.llm_budget_usd_per_day == 2.00

    def test_llm_provider_default(self):
        """Req 13.1: LLM_PROVIDER defaults to 'gemini'."""
        s = self._make_settings()
        assert s.llm_provider == "gemini"

    def test_llm_timeout_seconds_default(self):
        """Req 11.4: LLM_TIMEOUT_SECONDS defaults to 45."""
        s = self._make_settings()
        assert s.llm_timeout_seconds == 45

    def test_max_context_tokens_default(self):
        """Req 11.1: MAX_CONTEXT_TOKENS defaults to 12000."""
        s = self._make_settings()
        assert s.max_context_tokens == 12000

    def test_processing_timeout_seconds_default(self):
        """PROCESSING_TIMEOUT_SECONDS defaults to 240."""
        s = self._make_settings()
        assert s.processing_timeout_seconds == 240

    def test_log_lookback_minutes_default(self):
        """LOG_LOOKBACK_MINUTES defaults to 5."""
        s = self._make_settings()
        assert s.log_lookback_minutes == 5

    def test_log_lines_per_container_default(self):
        """LOG_LINES_PER_CONTAINER defaults to 100."""
        s = self._make_settings()
        assert s.log_lines_per_container == 100

    def test_redact_ipv4_default_false(self):
        """REDACT_IPV4 defaults to False."""
        s = self._make_settings()
        assert s.redact_ipv4 is False

    def test_dedup_ttl_seconds_default(self):
        """DEDUP_TTL_SECONDS defaults to 3600."""
        s = self._make_settings()
        assert s.dedup_ttl_seconds == 3600

    def test_instance_cache_ttl_sec_default(self):
        """INSTANCE_CACHE_TTL_SEC defaults to 60."""
        s = self._make_settings()
        assert s.instance_cache_ttl_sec == 60

    def test_window_max_open_seconds_default(self):
        """WINDOW_MAX_OPEN_SECONDS defaults to 1800."""
        s = self._make_settings()
        assert s.window_max_open_seconds == 1800


class TestSettingsEnvOverride:
    """Settings fields can be overridden via environment variables."""

    def _make_settings(self, **overrides):
        env = {
            "GCP_PROJECT_ID": "test-project",
            **overrides,
        }
        with patch.dict(os.environ, env, clear=False):
            from sre_agent.settings import Settings
            return Settings()

    def test_override_bootstrap_grace(self):
        s = self._make_settings(BOOTSTRAP_GRACE_SECONDS="900")
        assert s.bootstrap_grace_seconds == 900

    def test_override_correlation_window(self):
        s = self._make_settings(CORRELATION_WINDOW_SEC="120")
        assert s.correlation_window_sec == 120

    def test_override_cross_kind_correlation(self):
        s = self._make_settings(CROSS_KIND_CORRELATION_WINDOW_SEC="300")
        assert s.cross_kind_correlation_window_sec == 300

    def test_override_llm_provider(self):
        """Req 13.1: LLM_PROVIDER can be set to claude or openai."""
        s = self._make_settings(LLM_PROVIDER="claude")
        assert s.llm_provider == "claude"

    def test_override_llm_budget(self):
        s = self._make_settings(LLM_BUDGET_USD_PER_DAY="5.50")
        assert s.llm_budget_usd_per_day == 5.50

    def test_override_max_context_tokens(self):
        s = self._make_settings(MAX_CONTEXT_TOKENS="8000")
        assert s.max_context_tokens == 8000

    def test_gcp_project_id_required(self):
        """GCP_PROJECT_ID is required — no default."""
        with patch.dict(os.environ, {}, clear=True):
            from sre_agent.settings import Settings
            with pytest.raises(Exception):
                Settings()


class TestSettingsModuleSingleton:
    """Module-level `settings` instance is importable."""

    def test_settings_singleton_importable(self):
        """The module exposes a `settings` singleton for use across the codebase."""
        with patch.dict(os.environ, {"GCP_PROJECT_ID": "test-project"}):
            # Force reimport to pick up env
            import importlib
            import sre_agent.settings as mod
            importlib.reload(mod)
            assert hasattr(mod, "settings")
            assert mod.settings.gcp_project_id == "test-project"

    def test_project_id_property(self):
        """settings.project_id is a convenience alias for gcp_project_id."""
        with patch.dict(os.environ, {"GCP_PROJECT_ID": "my-gcp-proj"}):
            import importlib
            import sre_agent.settings as mod
            importlib.reload(mod)
            assert mod.settings.project_id == "my-gcp-proj"
