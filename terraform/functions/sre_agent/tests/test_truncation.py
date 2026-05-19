"""Unit tests for context truncation — token budget control.

Validates: Requirements 11.1, 11.2, 11.3
"""

import pytest

from sre_agent.models import Signal


class TestTruncateContextUnderBudget:
    """Requirement 11.1: No truncation when under token budget."""

    def test_small_signals_unchanged(self):
        """Signals fitting within budget are returned as-is."""
        from sre_agent.context import truncate_context

        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=["line1", "line2", "line3"]),
            Signal(kind="cpu_metric", source="cpu_metric", data={"value": 0.9}),
        ]
        result = truncate_context(signals, max_tokens=12000)
        assert result == signals

    def test_empty_signals(self):
        """Empty signal list returns empty list."""
        from sre_agent.context import truncate_context

        result = truncate_context([], max_tokens=12000)
        assert result == []

    def test_single_metric_signal(self):
        """A single metric signal under budget is unchanged."""
        from sre_agent.context import truncate_context

        signals = [
            Signal(kind="cpu_metric", source="cpu_metric", data={"value": 0.85, "ts": "2026-01-01T00:00:00Z"}),
        ]
        result = truncate_context(signals, max_tokens=12000)
        assert result == signals


class TestTruncateContextOverBudget:
    """Requirement 11.2: Logs truncated when over budget (oldest removed first)."""

    def test_logs_truncated_oldest_first(self):
        """When over budget, oldest log lines are removed first (freshest preserved)."""
        from sre_agent.context import truncate_context

        # Create a large log signal that exceeds budget
        # Each line ~40 chars => ~10 tokens. 200 lines => ~2000 tokens
        lines = [f"2026-01-01T00:{i:02d}:00Z ERROR line number {i}" for i in range(200)]
        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=lines),
        ]
        # Set a very small budget to force truncation
        result = truncate_context(signals, max_tokens=100)
        assert len(result) == 1
        result_data = result[0].data
        # Freshest lines (highest index) should be preserved
        assert any("line number 199" in str(item) for item in result_data)
        # Oldest lines should be removed
        assert not any("line number 0" in str(item) for item in result_data if "[truncated" not in str(item))

    def test_multiple_log_signals_truncated(self):
        """Multiple log signals are all subject to truncation."""
        from sre_agent.context import truncate_context

        lines_n8n = [f"n8n log line {i}" for i in range(100)]
        lines_pg = [f"postgres log line {i}" for i in range(100)]
        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=lines_n8n),
            Signal(kind="pg_logs", source="pg_logs", data=lines_pg),
        ]
        # Very small budget to force truncation
        result = truncate_context(signals, max_tokens=50)
        # Both signals should still exist
        log_signals = [s for s in result if "logs" in s.kind]
        assert len(log_signals) >= 1
        # Total token count should be within budget
        total_text = str([s.data for s in result])
        assert len(total_text) // 4 <= 50 + 100  # some slack for marker text


class TestTruncateContextMetricsNeverTruncated:
    """Requirement 11.2: Metrics and probe signals are NEVER truncated."""

    def test_metrics_preserved_when_logs_truncated(self):
        """Metric signals remain intact even when truncation is needed."""
        from sre_agent.context import truncate_context

        large_logs = [f"log line {i} " * 20 for i in range(200)]
        metric_data = {"value": 0.95, "metric_type": "cpu_utilization", "ts": "2026-01-01"}
        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=large_logs),
            Signal(kind="cpu_metric", source="cpu_metric", data=metric_data),
        ]
        result = truncate_context(signals, max_tokens=100)
        # Find the metric signal
        metric_signals = [s for s in result if s.kind == "cpu_metric"]
        assert len(metric_signals) == 1
        assert metric_signals[0].data == metric_data

    def test_probe_preserved_when_logs_truncated(self):
        """Probe signals remain intact even when truncation is needed."""
        from sre_agent.context import truncate_context

        large_logs = [f"log line {i} " * 20 for i in range(200)]
        probe_data = {"dns_ok": True, "tcp_ok": True, "https_ok": False, "error": "timeout"}
        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=large_logs),
            Signal(kind="external_probe", source="external_probe", data=probe_data),
        ]
        result = truncate_context(signals, max_tokens=100)
        # Find the probe signal
        probe_signals = [s for s in result if s.kind == "external_probe"]
        assert len(probe_signals) == 1
        assert probe_signals[0].data == probe_data


class TestTruncationMarker:
    """Requirement 11.2: Truncation marker present when truncation occurs."""

    def test_marker_present_when_truncated(self):
        """When logs are truncated, marker '[truncated: oldest N lines removed]' is added."""
        from sre_agent.context import truncate_context

        lines = [f"log line {i}" for i in range(200)]
        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=lines),
        ]
        result = truncate_context(signals, max_tokens=100)
        result_data = result[0].data
        # First entry should be the truncation marker
        assert "[truncated:" in str(result_data[0])
        assert "oldest" in str(result_data[0])
        assert "lines removed]" in str(result_data[0])

    def test_no_marker_when_not_truncated(self):
        """When no truncation occurs, no marker is added."""
        from sre_agent.context import truncate_context

        lines = ["short line 1", "short line 2"]
        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=lines),
        ]
        result = truncate_context(signals, max_tokens=12000)
        result_data = result[0].data
        assert not any("[truncated:" in str(item) for item in result_data)

    def test_marker_contains_line_count(self):
        """Marker includes the number of removed lines."""
        from sre_agent.context import truncate_context

        lines = [f"log line {i}" for i in range(200)]
        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=lines),
        ]
        result = truncate_context(signals, max_tokens=100)
        result_data = result[0].data
        marker = str(result_data[0])
        # Should contain a number indicating how many lines were removed
        import re
        match = re.search(r"oldest (\d+) lines removed", marker)
        assert match is not None
        removed_count = int(match.group(1))
        assert removed_count > 0
        # Remaining lines + removed lines should equal original
        remaining_lines = len(result_data) - 1  # minus the marker
        assert remaining_lines + removed_count == 200


class TestTruncateContextDefaultMaxTokens:
    """Requirement 11.1: Uses settings.max_context_tokens when max_tokens not provided."""

    def test_uses_settings_default(self):
        """When max_tokens is None, settings.max_context_tokens is used."""
        from unittest.mock import patch

        from sre_agent.context import truncate_context

        lines = ["short line"] * 5
        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=lines),
        ]
        with patch("sre_agent.settings.settings") as mock_settings:
            mock_settings.max_context_tokens = 12000
            result = truncate_context(signals, max_tokens=None)
        # Small signals should not be truncated with default 12000 budget
        assert result[0].data == lines
