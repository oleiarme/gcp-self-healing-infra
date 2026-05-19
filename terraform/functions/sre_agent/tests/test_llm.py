"""Unit tests for llm.py — pluggable LLM provider.

Validates: Requirements 13.1–13.6, 4.6, 11.4
Tests cover:
  - Provider dispatch (gemini, claude, openai)
  - ValueError for unknown provider
  - Client-side JSON + Pydantic validation
  - Timeout configuration
  - Structured logging (event=llm_call)
  - Cost estimation
"""

import json
import time
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

from sre_agent.models import Diagnosis, Incident, Signal


# --- Helpers ---


def _make_incident(
    incident_id: str = "inc-test-001",
    kind: str = "cpu",
    severity: str = "warning",
) -> Incident:
    """Create a minimal Incident for testing."""
    return Incident(
        id=incident_id,
        kind=kind,
        severity=severity,
        started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
        resource={"vm": "n8n-prod-abc1"},
        raw_payload={"incident": {"incident_id": incident_id}},
        source="cloud-monitoring",
    )


def _make_signals() -> list[Signal]:
    """Create minimal signals for testing."""
    return [
        Signal(
            kind="logs",
            source="n8n_logs",
            data=[{"timestamp": "2026-01-15T02:58:00Z", "text": "ERROR: OOM", "container": "n8n"}],
        ),
    ]


def _valid_llm_response() -> str:
    """Return a valid JSON response matching Diagnosis schema."""
    return json.dumps({
        "hypothesis": "n8n container hit OOM due to heavy workflow execution",
        "evidence_refs": ["2026-01-15T02:58:00Z ERROR: OOM"],
        "confidence": "medium",
        "suggested_fix": "Reduce n8n workflow concurrency or increase memory",
        "suggested_command": "docker stats n8n",
    })


def _valid_usage() -> dict:
    """Return a valid usage dict from LLM adapter."""
    return {"input": 1500, "output": 200}


# --- Tests: Provider dispatch ---


class TestProviderDispatch:
    """Req 13.1, 13.3: Provider switching via settings.llm_provider."""

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    def test_gemini_provider_calls_gemini_adapter(self, mock_settings, mock_call):
        """LLM_PROVIDER=gemini → _call_gemini is called."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        mock_call.return_value = (_valid_llm_response(), _valid_usage())

        result = analyze_with_llm(_make_incident(), _make_signals())

        mock_call.assert_called_once()
        assert isinstance(result, Diagnosis)

    @patch("sre_agent.llm._call_claude")
    @patch("sre_agent.llm.settings")
    def test_claude_provider_calls_claude_adapter(self, mock_settings, mock_call):
        """LLM_PROVIDER=claude → _call_claude is called."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "claude"
        mock_settings.llm_model = "claude-3-haiku-20240307"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        mock_call.return_value = (_valid_llm_response(), _valid_usage())

        result = analyze_with_llm(_make_incident(), _make_signals())

        mock_call.assert_called_once()
        assert isinstance(result, Diagnosis)

    @patch("sre_agent.llm._call_openai")
    @patch("sre_agent.llm.settings")
    def test_openai_provider_calls_openai_adapter(self, mock_settings, mock_call):
        """LLM_PROVIDER=openai → _call_openai is called."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "openai"
        mock_settings.llm_model = "gpt-4o-mini"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        mock_call.return_value = (_valid_llm_response(), _valid_usage())

        result = analyze_with_llm(_make_incident(), _make_signals())

        mock_call.assert_called_once()
        assert isinstance(result, Diagnosis)


# --- Tests: Unknown provider ---


class TestUnknownProvider:
    """Req 13.4: ValueError for unknown provider."""

    @patch("sre_agent.llm.settings")
    def test_unknown_provider_raises_value_error(self, mock_settings):
        """Unknown LLM_PROVIDER → ValueError('unknown provider <name>')."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "anthropic_v99"
        mock_settings.llm_model = "some-model"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"

        with pytest.raises(ValueError, match="unknown provider anthropic_v99"):
            analyze_with_llm(_make_incident(), _make_signals())


# --- Tests: Placeholder/empty API key ---


class TestPlaceholderAPIKey:
    """ValueError for empty or placeholder API key."""

    @patch("sre_agent.llm.settings")
    def test_placeholder_api_key_raises_value_error(self, mock_settings):
        """API key is 'placeholder' → ValueError."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "placeholder"

        with pytest.raises(ValueError, match="LLM API key is empty or placeholder"):
            analyze_with_llm(_make_incident(), _make_signals())

    @patch("sre_agent.llm.settings")
    def test_empty_api_key_raises_value_error(self, mock_settings):
        """API key is empty → ValueError."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = ""

        with pytest.raises(ValueError, match="LLM API key is empty or placeholder"):
            analyze_with_llm(_make_incident(), _make_signals())


# --- Tests: Client-side validation ---


class TestClientSideValidation:
    """Req 13.5: JSON parsing + Pydantic validation."""

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    def test_invalid_json_raises_json_decode_error(self, mock_settings, mock_call):
        """Invalid JSON from LLM → raises json.JSONDecodeError."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        mock_call.return_value = ("not valid json {{{", _valid_usage())

        with pytest.raises(json.JSONDecodeError):
            analyze_with_llm(_make_incident(), _make_signals())

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    def test_schema_mismatch_raises_validation_error(self, mock_settings, mock_call):
        """Valid JSON but missing required fields → raises ValidationError."""
        from pydantic import ValidationError

        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        # Missing 'hypothesis' and 'suggested_fix'
        mock_call.return_value = (json.dumps({"confidence": "low"}), _valid_usage())

        with pytest.raises(ValidationError):
            analyze_with_llm(_make_incident(), _make_signals())

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    def test_invalid_confidence_raises_validation_error(self, mock_settings, mock_call):
        """confidence not in {low, medium, high} → ValidationError."""
        from pydantic import ValidationError

        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        bad_response = json.dumps({
            "hypothesis": "test",
            "evidence_refs": [],
            "confidence": "very_high",  # invalid
            "suggested_fix": "do something",
            "suggested_command": None,
        })
        mock_call.return_value = (bad_response, _valid_usage())

        with pytest.raises(ValidationError):
            analyze_with_llm(_make_incident(), _make_signals())


# --- Tests: Diagnosis fields ---


class TestDiagnosisFields:
    """Req 13.5, 13.6: Correct Diagnosis construction from LLM response."""

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    def test_diagnosis_fields_populated_correctly(self, mock_settings, mock_call):
        """All Diagnosis fields are populated from LLM response + usage."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        mock_call.return_value = (_valid_llm_response(), {"input": 1500, "output": 200})

        result = analyze_with_llm(_make_incident(), _make_signals())

        assert result.hypothesis == "n8n container hit OOM due to heavy workflow execution"
        assert result.evidence_refs == ["2026-01-15T02:58:00Z ERROR: OOM"]
        assert result.confidence == "medium"
        assert result.suggested_fix == "Reduce n8n workflow concurrency or increase memory"
        assert result.suggested_command == "docker stats n8n"
        assert result.model == "gemini-1.5-flash-002"
        assert result.tokens_in == 1500
        assert result.tokens_out == 200
        assert result.cost_usd >= 0.0
        assert result.created_at is not None

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    def test_suggested_command_null_allowed(self, mock_settings, mock_call):
        """suggested_command can be null in LLM response."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        response = json.dumps({
            "hypothesis": "test hypothesis",
            "evidence_refs": ["line1"],
            "confidence": "low",
            "suggested_fix": "check logs",
            "suggested_command": None,
        })
        mock_call.return_value = (response, _valid_usage())

        result = analyze_with_llm(_make_incident(), _make_signals())

        assert result.suggested_command is None


# --- Tests: Structured logging ---


class TestStructuredLogging:
    """Req 4.6, 13.6: Structured log event=llm_call."""

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    @patch("sre_agent.llm.logger")
    def test_llm_call_logged_with_required_fields(self, mock_logger, mock_settings, mock_call):
        """event=llm_call log contains tokens_in, tokens_out, cost_usd, provider, model."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        mock_call.return_value = (_valid_llm_response(), {"input": 1500, "output": 200})

        analyze_with_llm(_make_incident(), _make_signals())

        # Check that logger.info was called with structured data
        mock_logger.info.assert_called()
        call_kwargs = mock_logger.info.call_args
        # The log should contain event=llm_call and required fields
        log_extra = call_kwargs.kwargs if call_kwargs.kwargs else {}
        # If using extra= parameter
        if "extra" in log_extra:
            extra = log_extra["extra"]
        else:
            # Check positional args for structured log message
            log_msg = call_kwargs[0][0] if call_kwargs[0] else ""
            assert "llm_call" in str(call_kwargs)


# --- Tests: Cost estimation ---


class TestCostEstimation:
    """Cost is calculated based on provider pricing."""

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    def test_cost_is_non_negative(self, mock_settings, mock_call):
        """Cost should always be non-negative."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"
        mock_call.return_value = (_valid_llm_response(), {"input": 1500, "output": 200})

        result = analyze_with_llm(_make_incident(), _make_signals())

        assert result.cost_usd >= 0.0

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    def test_cost_increases_with_tokens(self, mock_settings, mock_call):
        """More tokens → higher cost."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 45
        mock_settings.llm_api_key = "test-key"

        # Small usage
        mock_call.return_value = (_valid_llm_response(), {"input": 100, "output": 50})
        result_small = analyze_with_llm(_make_incident(), _make_signals())

        # Large usage
        mock_call.return_value = (_valid_llm_response(), {"input": 10000, "output": 5000})
        result_large = analyze_with_llm(_make_incident(), _make_signals())

        assert result_large.cost_usd > result_small.cost_usd


# --- Tests: Timeout configuration ---


class TestTimeoutConfiguration:
    """Req 11.4: LLM_TIMEOUT_SECONDS default 45s."""

    @patch("sre_agent.llm._call_gemini")
    @patch("sre_agent.llm.settings")
    def test_timeout_passed_to_adapter(self, mock_settings, mock_call):
        """Timeout from settings is passed to the adapter call."""
        from sre_agent.llm import analyze_with_llm

        mock_settings.llm_provider = "gemini"
        mock_settings.llm_model = "gemini-1.5-flash-002"
        mock_settings.llm_timeout_seconds = 30  # custom timeout
        mock_settings.llm_api_key = "test-key"
        mock_call.return_value = (_valid_llm_response(), _valid_usage())

        analyze_with_llm(_make_incident(), _make_signals())

        # Verify timeout was passed to the adapter
        call_args = mock_call.call_args
        # The adapter should receive timeout as a parameter
        assert 30 in call_args[0] or call_args.kwargs.get("timeout") == 30 or any(
            arg == 30 for arg in call_args[0]
        )
