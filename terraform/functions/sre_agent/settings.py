"""Единый источник конфигурации через Pydantic BaseSettings.

Все time-window константы, kill-switch, LLM-параметры, Telegram,
context-gathering параметры — через env-переменные.

Requirements: 4.2, 7.2, 9.1, 9.2, 11.1, 11.4, 13.1, 13.2
"""

from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """SRE-agent configuration — single source of truth.

    All fields map directly to environment variables (case-insensitive).
    No module-level magic numbers anywhere in the codebase — use
    ``settings.<field>`` instead.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )

    # ─── Identity / GCP ───────────────────────────────────────────────
    gcp_project_id: str
    default_zone: str = "us-central1-a"
    n8n_public_host: str = ""

    @property
    def project_id(self) -> str:
        """Convenience alias used throughout the codebase (settings.project_id)."""
        return self.gcp_project_id

    # ─── Kill-switch (Req 7.2) ────────────────────────────────────────
    sre_agent_enabled: bool = True

    @property
    def enabled(self) -> bool:
        """Convenience alias used throughout the codebase (settings.enabled)."""
        return self.sre_agent_enabled

    # ─── LLM (Req 4.2, 13.1, 13.2, 11.4) ────────────────────────────
    llm_provider: Literal["gemini", "claude", "openai"] = "gemini"
    llm_model: str = "gemini-1.5-flash-002"
    llm_budget_usd_per_day: float = 2.00
    llm_api_key: str = ""  # from Secret Manager via secret_environment_variables
    llm_timeout_seconds: int = 45

    # ─── Telegram ─────────────────────────────────────────────────────
    tg_bot_token: str = ""
    tg_chat_id: str = ""

    # ─── Context-gathering ────────────────────────────────────────────
    log_lookback_minutes: int = 5
    log_lines_per_container: int = 100
    max_context_tokens: int = 12000

    # ─── Processing ──────────────────────────────────────────────────
    processing_timeout_seconds: int = 240

    # ─── Redaction ────────────────────────────────────────────────────
    redact_ipv4: bool = False

    # ─── OS profile ──────────────────────────────────────────────────
    host_os: Literal["ubuntu", "cos"] = "cos"

    # ─── Time-window contract (Req 9.1, 9.2) ─────────────────────────
    # Single source of truth — env-overridable, synced with Terraform.
    bootstrap_grace_seconds: int = 1800
    live_migration_window_sec: int = 300
    correlation_window_sec: int = 90
    cross_kind_correlation_window_sec: int = 180

    # ─── Dedup & correlation store ────────────────────────────────────
    dedup_ttl_seconds: int = 3600
    window_max_open_seconds: int = 1800
    instance_cache_ttl_sec: int = 60


settings = Settings()  # type: ignore[call-arg]
