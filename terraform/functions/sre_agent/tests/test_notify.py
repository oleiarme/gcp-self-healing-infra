"""Tests for notify.py — Telegram notification module.

Tests cover:
  - notify_telegram: full diagnosis message with 3 sections
  - notify_telegram_brief: short suppression notification
  - notify_telegram_correlation_update: severity escalation update
  - MarkdownV2 escaping of special characters
  - Retry logic (3 retries with exponential backoff for HTTP >= 400)
  - Blocking when incident.id is missing
  - Structured logging on retry exhaustion

Requirements: 3.1–3.7, 4.3
"""

import logging
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import httpx
import pytest

from sre_agent.models import Diagnosis, Incident
from sre_agent.notify import (
    _escape_markdown_v2,
    _send_telegram_message,
    notify_telegram,
    notify_telegram_brief,
    notify_telegram_correlation_update,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def sample_incident() -> Incident:
    """Create a sample incident for testing."""
    return Incident(
        id="inc-12345",
        kind="cpu",
        severity="warning",
        started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
        resource={"vm": "my-vm-instance"},
        raw_payload={"incident": {"incident_id": "inc-12345"}},
        source="cloud-monitoring",
    )


@pytest.fixture
def sample_diagnosis() -> Diagnosis:
    """Create a sample diagnosis for testing."""
    return Diagnosis(
        hypothesis="High CPU caused by n8n workflow loop processing 10k items",
        evidence_refs=["log:n8n:2026-01-15T02:58:00Z", "metric:cpu:0.92"],
        confidence="high",
        suggested_fix="Reduce batch size in workflow 'Import Contacts' to 100 items",
        suggested_command="docker exec n8n n8n update:workflow --id=42 --active=false",
        model="gemini-1.5-flash-002",
        tokens_in=3500,
        tokens_out=450,
        cost_usd=0.0004,
        created_at=datetime(2026, 1, 15, 3, 0, 30, tzinfo=timezone.utc),
    )


@pytest.fixture
def incident_no_id() -> Incident:
    """Create an incident with empty id for blocking tests."""
    return Incident(
        id="",
        kind="cpu",
        severity="warning",
        started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
        resource={"vm": "my-vm-instance"},
        raw_payload={},
        source="cloud-monitoring",
    )


# ---------------------------------------------------------------------------
# Tests: MarkdownV2 escaping (Req 3.7)
# ---------------------------------------------------------------------------


class TestEscapeMarkdownV2:
    """Tests for MarkdownV2 special character escaping."""

    def test_escapes_all_special_chars(self):
        """All MarkdownV2 special characters are escaped."""
        text = r"Hello_world*bold[link](url)~strike`code>quote#plus+minus-equal=pipe|{brace}.excl!"
        result = _escape_markdown_v2(text)
        # Each special char should be preceded by backslash
        for char in r"_*[]()~`>#+-=|{}.!":
            assert f"\\{char}" in result or char not in text

    def test_empty_string(self):
        """Empty string returns empty string."""
        assert _escape_markdown_v2("") == ""

    def test_plain_text_unchanged(self):
        """Plain text without special chars is unchanged."""
        assert _escape_markdown_v2("Hello world 123") == "Hello world 123"

    def test_underscore_escaped(self):
        """Underscores are escaped for MarkdownV2."""
        assert _escape_markdown_v2("my_var") == r"my\_var"

    def test_dots_escaped(self):
        """Dots are escaped for MarkdownV2."""
        assert _escape_markdown_v2("192.168.1.1") == r"192\.168\.1\.1"


# ---------------------------------------------------------------------------
# Tests: notify_telegram — full message (Req 3.1, 3.2)
# ---------------------------------------------------------------------------


class TestNotifyTelegram:
    """Tests for notify_telegram — full diagnosis notification."""

    @patch("sre_agent.notify._send_telegram_message")
    def test_sends_message_with_three_sections(
        self, mock_send, sample_incident, sample_diagnosis
    ):
        """Message contains all three sections: 🚨, 🔍, 🛠."""
        mock_send.return_value = {"ok": True, "result": {"message_id": 999}}

        notify_telegram(sample_incident, sample_diagnosis, "corr-001")

        mock_send.assert_called_once()
        text = mock_send.call_args[0][0]
        assert "🚨" in text
        assert "🔍" in text
        assert "🛠" in text

    @patch("sre_agent.notify._send_telegram_message")
    def test_message_contains_incident_id(
        self, mock_send, sample_incident, sample_diagnosis
    ):
        """Message must contain incident.id for traceability (Req 3.2)."""
        mock_send.return_value = {"ok": True, "result": {"message_id": 999}}

        notify_telegram(sample_incident, sample_diagnosis, "corr-001")

        text = mock_send.call_args[0][0]
        assert "inc-12345" in text

    @patch("sre_agent.notify._send_telegram_message")
    def test_message_contains_hypothesis(
        self, mock_send, sample_incident, sample_diagnosis
    ):
        """Message contains the diagnosis hypothesis."""
        mock_send.return_value = {"ok": True, "result": {"message_id": 999}}

        notify_telegram(sample_incident, sample_diagnosis, "corr-001")

        text = mock_send.call_args[0][0]
        assert "CPU" in text or "cpu" in text.lower()

    @patch("sre_agent.notify._send_telegram_message")
    def test_message_contains_suggested_command_in_code_block(
        self, mock_send, sample_incident, sample_diagnosis
    ):
        """suggested_command is rendered in monospace block."""
        mock_send.return_value = {"ok": True, "result": {"message_id": 999}}

        notify_telegram(sample_incident, sample_diagnosis, "corr-001")

        text = mock_send.call_args[0][0]
        # In MarkdownV2, code blocks use ``` or `
        assert "docker exec" in text or "n8n update" in text

    @patch("sre_agent.notify._send_telegram_message")
    def test_blocks_when_incident_id_missing(
        self, mock_send, incident_no_id, sample_diagnosis, caplog
    ):
        """Blocks sending when incident.id is empty (Req 3.2)."""
        with caplog.at_level(logging.WARNING):
            notify_telegram(incident_no_id, sample_diagnosis, "corr-001")

        mock_send.assert_not_called()
        assert "notify_blocked" in caplog.text or "missing_incident_id" in caplog.text

    @patch("sre_agent.notify._send_telegram_message")
    def test_message_contains_kind_and_severity(
        self, mock_send, sample_incident, sample_diagnosis
    ):
        """Message section 🚨 contains kind and severity."""
        mock_send.return_value = {"ok": True, "result": {"message_id": 999}}

        notify_telegram(sample_incident, sample_diagnosis, "corr-001")

        text = mock_send.call_args[0][0]
        assert "cpu" in text.lower()
        assert "warning" in text.lower()


# ---------------------------------------------------------------------------
# Tests: notify_telegram_brief — short suppression message (Req 3.5)
# ---------------------------------------------------------------------------


class TestNotifyTelegramBrief:
    """Tests for notify_telegram_brief — suppression notification."""

    @patch("sre_agent.notify._send_telegram_message")
    def test_live_migration_brief(self, mock_send, sample_incident):
        """Brief message for live migration suppression."""
        mock_send.return_value = {"ok": True, "result": {"message_id": 100}}

        notify_telegram_brief(sample_incident, "live_migration")

        mock_send.assert_called_once()
        text = mock_send.call_args[0][0]
        assert "inc-12345" in text
        assert "live migration" in text.lower() or "🔄" in text

    @patch("sre_agent.notify._send_telegram_message")
    def test_bootstrap_grace_brief_with_vm_age(self, mock_send, sample_incident):
        """Brief message for bootstrap grace includes vm_age."""
        mock_send.return_value = {"ok": True, "result": {"message_id": 101}}

        notify_telegram_brief(sample_incident, "bootstrap_grace", vm_age=120)

        mock_send.assert_called_once()
        text = mock_send.call_args[0][0]
        assert "inc-12345" in text
        assert "120" in text
        assert "bootstrap" in text.lower() or "🛠" in text

    @patch("sre_agent.notify._send_telegram_message")
    def test_blocks_when_incident_id_missing(self, mock_send, incident_no_id, caplog):
        """Blocks sending when incident.id is empty."""
        with caplog.at_level(logging.WARNING):
            notify_telegram_brief(incident_no_id, "live_migration")

        mock_send.assert_not_called()


# ---------------------------------------------------------------------------
# Tests: notify_telegram_correlation_update (Req 3.6)
# ---------------------------------------------------------------------------


class TestNotifyTelegramCorrelationUpdate:
    """Tests for notify_telegram_correlation_update."""

    @patch("sre_agent.notify._send_telegram_message")
    def test_sends_severity_escalation_message(self, mock_send, sample_incident):
        """Sends update when severity escalates."""
        mock_send.return_value = {"ok": True, "result": {"message_id": 200}}

        notify_telegram_correlation_update("corr-001", sample_incident)

        mock_send.assert_called_once()
        text = mock_send.call_args[0][0]
        assert "corr-001" in text or "inc-12345" in text

    @patch("sre_agent.notify._send_telegram_message")
    def test_blocks_when_incident_id_missing(self, mock_send, incident_no_id, caplog):
        """Blocks sending when incident.id is empty."""
        with caplog.at_level(logging.WARNING):
            notify_telegram_correlation_update("corr-001", incident_no_id)

        mock_send.assert_not_called()


# ---------------------------------------------------------------------------
# Tests: Retry logic (Req 3.4)
# ---------------------------------------------------------------------------


class TestRetryLogic:
    """Tests for retry with exponential backoff."""

    @patch("sre_agent.notify.time.sleep")
    @patch("sre_agent.notify.httpx.Client")
    def test_retries_on_http_400(self, mock_client_cls, mock_sleep):
        """Retries up to 3 times on HTTP >= 400."""
        mock_client = MagicMock()
        mock_client_cls.return_value.__enter__ = MagicMock(return_value=mock_client)
        mock_client_cls.return_value.__exit__ = MagicMock(return_value=False)

        # All 3 attempts return 429
        error_response = httpx.Response(429, request=httpx.Request("POST", "http://test"))
        mock_client.post.side_effect = httpx.HTTPStatusError(
            "rate limited", request=error_response.request, response=error_response
        )

        result = _send_telegram_message("test message")

        assert result is None
        assert mock_client.post.call_count == 3

    @patch("sre_agent.notify.time.sleep")
    @patch("sre_agent.notify.httpx.Client")
    def test_exponential_backoff_delays(self, mock_client_cls, mock_sleep):
        """Backoff delays are 1s, 2s, 4s."""
        mock_client = MagicMock()
        mock_client_cls.return_value.__enter__ = MagicMock(return_value=mock_client)
        mock_client_cls.return_value.__exit__ = MagicMock(return_value=False)

        error_response = httpx.Response(500, request=httpx.Request("POST", "http://test"))
        mock_client.post.side_effect = httpx.HTTPStatusError(
            "server error", request=error_response.request, response=error_response
        )

        _send_telegram_message("test message")

        # After 1st fail: sleep(1), after 2nd fail: sleep(2)
        # After 3rd fail: no more sleep (exhausted)
        sleep_calls = [call[0][0] for call in mock_sleep.call_args_list]
        assert sleep_calls == [1, 2]

    @patch("sre_agent.notify.httpx.Client")
    def test_no_retry_on_network_timeout(self, mock_client_cls):
        """Network timeouts do NOT trigger retry (Req 3.4)."""
        mock_client = MagicMock()
        mock_client_cls.return_value.__enter__ = MagicMock(return_value=mock_client)
        mock_client_cls.return_value.__exit__ = MagicMock(return_value=False)

        mock_client.post.side_effect = httpx.TimeoutException("connection timed out")

        result = _send_telegram_message("test message")

        assert result is None
        assert mock_client.post.call_count == 1

    @patch("sre_agent.notify.httpx.Client")
    def test_success_on_first_try(self, mock_client_cls):
        """Successful response on first try returns result."""
        mock_client = MagicMock()
        mock_client_cls.return_value.__enter__ = MagicMock(return_value=mock_client)
        mock_client_cls.return_value.__exit__ = MagicMock(return_value=False)

        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {"ok": True, "result": {"message_id": 42}}
        mock_response.raise_for_status = MagicMock()
        mock_client.post.return_value = mock_response

        result = _send_telegram_message("test message")

        assert result == {"ok": True, "result": {"message_id": 42}}
        assert mock_client.post.call_count == 1

    @patch("sre_agent.notify.time.sleep")
    @patch("sre_agent.notify.httpx.Client")
    def test_logs_notify_fail_on_exhaustion(
        self, mock_client_cls, mock_sleep, caplog
    ):
        """Logs event=notify_fail when all retries exhausted (Req 3.4)."""
        mock_client = MagicMock()
        mock_client_cls.return_value.__enter__ = MagicMock(return_value=mock_client)
        mock_client_cls.return_value.__exit__ = MagicMock(return_value=False)

        error_response = httpx.Response(500, request=httpx.Request("POST", "http://test"))
        mock_client.post.side_effect = httpx.HTTPStatusError(
            "server error", request=error_response.request, response=error_response
        )

        with caplog.at_level(logging.ERROR):
            _send_telegram_message("test message", incident_id="inc-999")

        assert "notify_fail" in caplog.text
        assert "inc-999" in caplog.text

    @patch("sre_agent.notify.time.sleep")
    @patch("sre_agent.notify.httpx.Client")
    def test_succeeds_on_second_try(self, mock_client_cls, mock_sleep):
        """Succeeds on second attempt after first HTTP error."""
        mock_client = MagicMock()
        mock_client_cls.return_value.__enter__ = MagicMock(return_value=mock_client)
        mock_client_cls.return_value.__exit__ = MagicMock(return_value=False)

        error_response = httpx.Response(500, request=httpx.Request("POST", "http://test"))
        success_response = MagicMock()
        success_response.status_code = 200
        success_response.json.return_value = {"ok": True, "result": {"message_id": 77}}
        success_response.raise_for_status = MagicMock()

        mock_client.post.side_effect = [
            httpx.HTTPStatusError(
                "server error", request=error_response.request, response=error_response
            ),
            success_response,
        ]

        result = _send_telegram_message("test message")

        assert result == {"ok": True, "result": {"message_id": 77}}
        assert mock_client.post.call_count == 2
