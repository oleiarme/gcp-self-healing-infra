"""Unit tests for context.py — get_logs, get_metric_series, gather_context, get_cloudflared_logs.

Validates: Requirements 2.1–2.5, 2.9, 11.2, 11.3

Tests cover:
  - get_logs: heterogeneous filter (Ubuntu + COS), limit, partial on API error
  - get_metric_series: queries CPU utilization metric
  - gather_context: orchestrates logs + metrics + external probe for external_unreachable
  - get_cloudflared_logs: same pattern as get_logs for cloudflared container
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch, PropertyMock

import pytest

from sre_agent.models import Incident, LogLine, Metric, Signal


# --- Helpers ---


def _make_incident(
    kind: str = "cpu",
    started_at: datetime | None = None,
    resource: dict | None = None,
) -> Incident:
    """Build a minimal Incident for testing."""
    return Incident(
        id="inc-test-001",
        kind=kind,
        severity="warning",
        started_at=started_at or datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc),
        resource=resource or {"vm": "n8n-prod-abc1"},
        raw_payload={"incident": {"incident_id": "inc-test-001"}},
        source="cloud-monitoring",
    )


def _make_log_entry(timestamp=None, payload="test log line", container="n8n"):
    """Create a mock Cloud Logging entry."""
    entry = MagicMock()
    entry.timestamp = timestamp or datetime(2026, 6, 15, 9, 58, 0, tzinfo=timezone.utc)
    entry.payload = payload
    entry.severity = "ERROR"
    return entry


# --- Tests: get_logs ---


class TestGetLogs:
    """Req 2.1, 2.3, 2.4, 2.5: get_logs with heterogeneous filter."""

    @patch("sre_agent.context._logging")
    def test_returns_log_lines_and_partial_false_on_success(self, mock_logging):
        """get_logs returns (list[LogLine], False) on successful API call."""
        from sre_agent.context import get_logs

        mock_entries = [_make_log_entry(payload=f"line {i}") for i in range(3)]
        mock_logging.list_entries.return_value = iter(mock_entries)

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        lines, partial = get_logs("test-project", "n8n", since, 5, 100)

        assert partial is False
        assert len(lines) == 3
        assert all(isinstance(line, LogLine) for line in lines)

    @patch("sre_agent.context._logging")
    def test_heterogeneous_filter_contains_both_os_patterns(self, mock_logging):
        """Req 2.5: Filter uses OR for Ubuntu labels + COS jsonPayload."""
        from sre_agent.context import get_logs

        mock_logging.list_entries.return_value = iter([])

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        get_logs("test-project", "n8n", since, 5, 100)

        call_args = mock_logging.list_entries.call_args
        filter_str = call_args[1].get("filter_") or call_args[0][0] if call_args[0] else call_args[1].get("filter_")
        assert 'labels."container_name"="n8n"' in filter_str
        assert 'jsonPayload.container.name="n8n"' in filter_str

    @patch("sre_agent.context._logging")
    def test_respects_max_lines_limit(self, mock_logging):
        """Req 2.1: Limits to LOG_LINES_PER_CONTAINER entries."""
        from sre_agent.context import get_logs

        mock_entries = [_make_log_entry(payload=f"line {i}") for i in range(200)]
        mock_logging.list_entries.return_value = iter(mock_entries)

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        lines, partial = get_logs("test-project", "n8n", since, 5, 100)

        assert len(lines) <= 100

    @patch("sre_agent.context._logging")
    def test_graceful_degradation_on_api_error(self, mock_logging):
        """Req 2.9: Returns partial=True on Cloud Logging API error."""
        from google.api_core.exceptions import ResourceExhausted
        from sre_agent.context import get_logs

        mock_logging.list_entries.side_effect = ResourceExhausted("quota exceeded")

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        lines, partial = get_logs("test-project", "n8n", since, 5, 100)

        assert partial is True
        assert lines == []

    @patch("sre_agent.context._logging")
    def test_graceful_degradation_on_5xx(self, mock_logging):
        """Req 2.9: Returns partial=True on 5xx server error."""
        from google.api_core.exceptions import InternalServerError
        from sre_agent.context import get_logs

        mock_logging.list_entries.side_effect = InternalServerError("internal error")

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        lines, partial = get_logs("test-project", "n8n", since, 5, 100)

        assert partial is True
        assert lines == []

    @patch("sre_agent.context._logging")
    def test_graceful_degradation_on_timeout(self, mock_logging):
        """Req 2.9: Returns partial=True on timeout."""
        from google.api_core.exceptions import DeadlineExceeded
        from sre_agent.context import get_logs

        mock_logging.list_entries.side_effect = DeadlineExceeded("timeout")

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        lines, partial = get_logs("test-project", "n8n", since, 5, 100)

        assert partial is True
        assert lines == []

    @patch("sre_agent.context._logging")
    def test_log_line_fields_populated(self, mock_logging):
        """LogLine has timestamp, text, container fields."""
        from sre_agent.context import get_logs

        entry = _make_log_entry(
            timestamp=datetime(2026, 6, 15, 9, 58, 30, tzinfo=timezone.utc),
            payload="ERROR: connection refused",
        )
        mock_logging.list_entries.return_value = iter([entry])

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        lines, partial = get_logs("test-project", "n8n", since, 5, 100)

        assert len(lines) == 1
        assert lines[0].container == "n8n"
        assert "connection refused" in lines[0].text
        assert lines[0].timestamp == datetime(2026, 6, 15, 9, 58, 30, tzinfo=timezone.utc)


# --- Tests: get_metric_series ---


class TestGetMetricSeries:
    """Req 2.2: get_metric_series queries CPU utilization."""

    @patch("sre_agent.context._metrics")
    def test_returns_metric_points(self, mock_metrics):
        """Returns list of Metric points from monitoring API."""
        from sre_agent.context import get_metric_series

        # Mock a time series with points
        mock_point = MagicMock()
        mock_point.value.double_value = 0.87
        mock_point.interval.end_time = datetime(2026, 6, 15, 9, 59, 0, tzinfo=timezone.utc)

        mock_ts = MagicMock()
        mock_ts.points = [mock_point]

        mock_metrics.list_time_series.return_value = iter([mock_ts])

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        metrics = get_metric_series(
            "test-project",
            "123456789",
            since,
            5,
        )

        assert len(metrics) == 1
        assert isinstance(metrics[0], Metric)
        assert metrics[0].value == 0.87
        assert metrics[0].metric_type == "compute.googleapis.com/instance/cpu/utilization"

    @patch("sre_agent.context._metrics")
    def test_returns_empty_on_no_data(self, mock_metrics):
        """Returns empty list when no time series data."""
        from sre_agent.context import get_metric_series

        mock_metrics.list_time_series.return_value = iter([])

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        metrics = get_metric_series("test-project", "123456789", since, 5)

        assert metrics == []


# --- Tests: get_cloudflared_logs ---


class TestGetCloudflaredLogs:
    """get_cloudflared_logs uses same pattern as get_logs for cloudflared."""

    @patch("sre_agent.context.get_logs")
    def test_delegates_to_get_logs_with_cloudflared(self, mock_get_logs):
        """get_cloudflared_logs calls get_logs with container='cloudflared'."""
        from sre_agent.context import get_cloudflared_logs

        mock_get_logs.return_value = ([LogLine(
            timestamp=datetime(2026, 6, 15, 9, 58, 0, tzinfo=timezone.utc),
            text="tunnel connected",
            container="cloudflared",
        )], False)

        since = datetime(2026, 6, 15, 9, 55, 0, tzinfo=timezone.utc)
        lines, partial = get_cloudflared_logs("test-project", since, 5, 100)

        mock_get_logs.assert_called_once_with("test-project", "cloudflared", since, 5, 100)
        assert len(lines) == 1
        assert lines[0].container == "cloudflared"


# --- Tests: gather_context ---


class TestGatherContext:
    """Req 2.1, 2.2, 2.6: gather_context orchestrates context collection."""

    @patch("sre_agent.context.get_metric_series")
    @patch("sre_agent.context.get_logs")
    def test_collects_n8n_postgres_logs_and_cpu_metrics(self, mock_get_logs, mock_get_metrics):
        """Req 2.1, 2.2: Collects n8n logs, postgres logs, and CPU metrics."""
        from sre_agent.context import gather_context

        mock_get_logs.return_value = ([], False)
        mock_get_metrics.return_value = []

        incident = _make_incident(kind="cpu")
        settings = MagicMock()
        settings.project_id = "test-project"
        settings.log_lookback_minutes = 5
        settings.log_lines_per_container = 100
        settings.n8n_public_host = "n8n.example.com"

        signals, metadata = gather_context(incident, settings)

        assert isinstance(signals, list)
        assert isinstance(metadata, dict)
        # Should have at least n8n_logs, pg_logs, cpu_metric signals
        signal_kinds = [s.kind for s in signals]
        assert "n8n_logs" in signal_kinds
        assert "pg_logs" in signal_kinds
        assert "cpu_metric" in signal_kinds

    @patch("sre_agent.context.get_cloudflared_logs")
    @patch("sre_agent.context.probe_external_reachability")
    @patch("sre_agent.context.get_metric_series")
    @patch("sre_agent.context.get_logs")
    def test_external_unreachable_adds_probe_and_cloudflared(
        self, mock_get_logs, mock_get_metrics, mock_probe, mock_cf_logs
    ):
        """Req 2.6: external_unreachable adds probe + cloudflared logs."""
        from sre_agent.context import gather_context

        mock_get_logs.return_value = ([], False)
        mock_get_metrics.return_value = []
        mock_probe.return_value = {"dns_ok": True, "tcp_ok": True}
        mock_cf_logs.return_value = ([], False)

        incident = _make_incident(
            kind="external_unreachable",
            resource={"vm": "n8n-prod", "public_host": "n8n.example.com"},
        )
        settings = MagicMock()
        settings.project_id = "test-project"
        settings.log_lookback_minutes = 5
        settings.log_lines_per_container = 100
        settings.n8n_public_host = "n8n.example.com"

        signals, metadata = gather_context(incident, settings)

        signal_kinds = [s.kind for s in signals]
        assert "external_probe" in signal_kinds
        assert "cloudflared_logs" in signal_kinds
        mock_probe.assert_called_once()
        mock_cf_logs.assert_called_once()

    @patch("sre_agent.context.get_metric_series")
    @patch("sre_agent.context.get_logs")
    def test_non_external_does_not_add_probe(self, mock_get_logs, mock_get_metrics):
        """Non-external_unreachable incidents don't call probe or cloudflared."""
        from sre_agent.context import gather_context

        mock_get_logs.return_value = ([], False)
        mock_get_metrics.return_value = []

        incident = _make_incident(kind="cpu")
        settings = MagicMock()
        settings.project_id = "test-project"
        settings.log_lookback_minutes = 5
        settings.log_lines_per_container = 100
        settings.n8n_public_host = "n8n.example.com"

        signals, metadata = gather_context(incident, settings)

        signal_kinds = [s.kind for s in signals]
        assert "external_probe" not in signal_kinds
        assert "cloudflared_logs" not in signal_kinds

    @patch("sre_agent.context.get_metric_series")
    @patch("sre_agent.context.get_logs")
    def test_partial_true_when_logs_fail(self, mock_get_logs, mock_get_metrics):
        """Req 2.9: metadata.partial=True when any log collection fails."""
        from sre_agent.context import gather_context

        # First call (n8n) succeeds, second call (postgres) returns partial
        mock_get_logs.side_effect = [
            ([], False),  # n8n logs OK
            ([], True),   # postgres logs partial
        ]
        mock_get_metrics.return_value = []

        incident = _make_incident(kind="cpu")
        settings = MagicMock()
        settings.project_id = "test-project"
        settings.log_lookback_minutes = 5
        settings.log_lines_per_container = 100
        settings.n8n_public_host = "n8n.example.com"

        signals, metadata = gather_context(incident, settings)

        assert metadata["partial"] is True
        assert "partial_reason" in metadata

    @patch("sre_agent.context.get_metric_series")
    @patch("sre_agent.context.get_logs")
    def test_partial_false_when_all_succeed(self, mock_get_logs, mock_get_metrics):
        """metadata.partial=False when all collections succeed."""
        from sre_agent.context import gather_context

        mock_get_logs.return_value = ([], False)
        mock_get_metrics.return_value = []

        incident = _make_incident(kind="cpu")
        settings = MagicMock()
        settings.project_id = "test-project"
        settings.log_lookback_minutes = 5
        settings.log_lines_per_container = 100
        settings.n8n_public_host = "n8n.example.com"

        signals, metadata = gather_context(incident, settings)

        assert metadata["partial"] is False

    @patch("sre_agent.context.get_metric_series")
    @patch("sre_agent.context.get_logs")
    def test_lookback_window_uses_settings(self, mock_get_logs, mock_get_metrics):
        """Uses settings.log_lookback_minutes for time window."""
        from sre_agent.context import gather_context

        mock_get_logs.return_value = ([], False)
        mock_get_metrics.return_value = []

        started_at = datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc)
        incident = _make_incident(kind="cpu", started_at=started_at)
        settings = MagicMock()
        settings.project_id = "test-project"
        settings.log_lookback_minutes = 5
        settings.log_lines_per_container = 100
        settings.n8n_public_host = "n8n.example.com"

        gather_context(incident, settings)

        # Verify get_logs is called with started_at and lookback_minutes from settings
        first_call = mock_get_logs.call_args_list[0]
        actual_started_at = first_call[0][2]  # third positional arg (started_at)
        actual_lookback = first_call[0][3]    # fourth positional arg (lookback_minutes)
        assert actual_started_at == started_at
        assert actual_lookback == 5
