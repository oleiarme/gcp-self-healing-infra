"""Unit tests for SRE-agent Pydantic models.

Validates: Requirements 1.1–1.6, 3.1, 6.5
"""

from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from sre_agent.models import (
    Diagnosis,
    Incident,
    LogLine,
    Metric,
    Notification,
    Signal,
)


# --- LogLine ---


class TestLogLine:
    def test_valid_logline(self):
        line = LogLine(
            timestamp=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
            text="FATAL: password authentication failed for user 'n8n'",
            container="postgres",
        )
        assert line.timestamp == datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc)
        assert line.text == "FATAL: password authentication failed for user 'n8n'"
        assert line.container == "postgres"

    def test_logline_container_optional(self):
        line = LogLine(
            timestamp=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
            text="kernel: Out of memory: Killed process 1234",
        )
        assert line.container is None

    def test_logline_missing_required_fields(self):
        with pytest.raises(ValidationError):
            LogLine(text="some text")  # missing timestamp


# --- Metric ---


class TestMetric:
    def test_valid_metric(self):
        m = Metric(
            timestamp=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
            value=0.92,
            metric_type="cpu_utilization",
        )
        assert m.timestamp == datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc)
        assert m.value == 0.92
        assert m.metric_type == "cpu_utilization"

    def test_metric_missing_required_fields(self):
        with pytest.raises(ValidationError):
            Metric(value=0.5)  # missing timestamp and metric_type


# --- Signal ---


class TestSignal:
    def test_valid_signal_with_list_data(self):
        sig = Signal(
            kind="n8n_logs",
            source="n8n_logs",
            data=[{"ts": "2026-01-15T03:00:00Z", "text": "ERROR"}],
        )
        assert sig.kind == "n8n_logs"
        assert sig.source == "n8n_logs"
        assert isinstance(sig.data, list)

    def test_valid_signal_with_dict_data(self):
        sig = Signal(
            kind="external_probe",
            source="external_probe",
            data={"dns_ok": True, "tcp_ok": True},
        )
        assert sig.kind == "external_probe"
        assert sig.source == "external_probe"
        assert isinstance(sig.data, dict)

    def test_signal_missing_required_fields(self):
        with pytest.raises(ValidationError):
            Signal(kind="cpu_metric")  # missing source and data


# --- Incident ---


class TestIncident:
    def test_valid_incident_cpu(self):
        inc = Incident(
            id="abc123",
            kind="cpu",
            severity="warning",
            started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
            resource={"vm": "n8n-prod-abc1"},
            raw_payload={"incident": {"incident_id": "abc123"}},
            source="cloud-monitoring",
        )
        assert inc.id == "abc123"
        assert inc.kind == "cpu"
        assert inc.severity == "warning"
        assert inc.source == "cloud-monitoring"

    def test_valid_incident_all_kinds(self):
        """All 5 incident kinds should be accepted."""
        kinds = ["cpu", "mem", "pg_fatal", "n8n_error", "external_unreachable"]
        for kind in kinds:
            inc = Incident(
                id=f"inc-{kind}",
                kind=kind,
                severity="warning",
                started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
                resource={"vm": "n8n-prod"},
                raw_payload={},
                source="cloud-monitoring",
            )
            assert inc.kind == kind

    def test_invalid_kind_rejected(self):
        with pytest.raises(ValidationError):
            Incident(
                id="inc-bad",
                kind="unknown_kind",
                severity="warning",
                started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
                resource={"vm": "n8n-prod"},
                raw_payload={},
                source="cloud-monitoring",
            )

    def test_severity_literal(self):
        """severity must be 'warning' or 'critical'."""
        inc = Incident(
            id="inc-crit",
            kind="pg_fatal",
            severity="critical",
            started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
            resource={"vm": "n8n-prod"},
            raw_payload={},
            source="cloud-monitoring",
        )
        assert inc.severity == "critical"

    def test_invalid_severity_rejected(self):
        with pytest.raises(ValidationError):
            Incident(
                id="inc-bad",
                kind="cpu",
                severity="info",  # not in Literal
                started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
                resource={"vm": "n8n-prod"},
                raw_payload={},
                source="cloud-monitoring",
            )

    def test_resource_with_public_host(self):
        inc = Incident(
            id="inc-ext",
            kind="external_unreachable",
            severity="critical",
            started_at=datetime(2026, 1, 15, 3, 0, 0, tzinfo=timezone.utc),
            resource={"vm": "n8n-prod", "public_host": "n8n.example.com"},
            raw_payload={},
            source="cloud-monitoring",
        )
        assert inc.resource["public_host"] == "n8n.example.com"

    def test_incident_missing_required_fields(self):
        with pytest.raises(ValidationError):
            Incident(id="inc-bad", kind="cpu")  # missing many fields


# --- Diagnosis ---


class TestDiagnosis:
    def test_valid_diagnosis(self):
        diag = Diagnosis(
            hypothesis="OOM kill due to n8n workflow memory leak",
            evidence_refs=["log:abc123", "metric:cpu/util"],
            confidence="high",
            suggested_fix="Restart n8n container and limit workflow concurrency",
            suggested_command="docker restart n8n",
            model="gemini-2.0-flash",
            tokens_in=1500,
            tokens_out=300,
            cost_usd=0.0012,
            created_at=datetime(2026, 1, 15, 3, 1, 0, tzinfo=timezone.utc),
        )
        assert diag.hypothesis == "OOM kill due to n8n workflow memory leak"
        assert diag.confidence == "high"
        assert diag.model == "gemini-2.0-flash"
        assert diag.tokens_in == 1500
        assert diag.tokens_out == 300
        assert diag.cost_usd == 0.0012

    def test_diagnosis_suggested_command_optional(self):
        diag = Diagnosis(
            hypothesis="Unknown issue",
            evidence_refs=[],
            confidence="low",
            suggested_fix="Check logs manually",
            suggested_command=None,
            model="rule-based-v1",
            tokens_in=0,
            tokens_out=0,
            cost_usd=0.0,
            created_at=datetime(2026, 1, 15, 3, 1, 0, tzinfo=timezone.utc),
        )
        assert diag.suggested_command is None

    def test_diagnosis_confidence_literal(self):
        """confidence must be 'low', 'medium', or 'high'."""
        with pytest.raises(ValidationError):
            Diagnosis(
                hypothesis="test",
                evidence_refs=[],
                confidence="very_high",  # invalid
                suggested_fix="test",
                suggested_command=None,
                model="gemini-2.0-flash",
                tokens_in=0,
                tokens_out=0,
                cost_usd=0.0,
                created_at=datetime(2026, 1, 15, 3, 1, 0, tzinfo=timezone.utc),
            )

    def test_diagnosis_rule_based_model(self):
        """Rule-based fallback uses model='rule-based-v1' (Req 6.5)."""
        diag = Diagnosis(
            hypothesis="[budget exhausted] Possible OOM",
            evidence_refs=["log:xyz"],
            confidence="low",
            suggested_fix="Check memory usage",
            suggested_command=None,
            model="rule-based-v1",
            tokens_in=0,
            tokens_out=0,
            cost_usd=0.0,
            created_at=datetime(2026, 1, 15, 3, 1, 0, tzinfo=timezone.utc),
        )
        assert diag.model == "rule-based-v1"
        assert diag.confidence == "low"


# --- Notification ---


class TestNotification:
    def test_valid_notification(self):
        notif = Notification(
            incident_id="inc-123",
            channel="telegram",
            message_id="msg_456",
            sent_at=datetime(2026, 1, 15, 3, 1, 30, tzinfo=timezone.utc),
            success=True,
        )
        assert notif.incident_id == "inc-123"
        assert notif.channel == "telegram"
        assert notif.message_id == "msg_456"
        assert notif.success is True

    def test_notification_failure(self):
        notif = Notification(
            incident_id="inc-123",
            channel="telegram",
            message_id="",
            sent_at=datetime(2026, 1, 15, 3, 1, 30, tzinfo=timezone.utc),
            success=False,
            error="HTTP 429 Too Many Requests",
        )
        assert notif.success is False
        assert notif.error == "HTTP 429 Too Many Requests"

    def test_notification_error_optional(self):
        notif = Notification(
            incident_id="inc-123",
            channel="telegram",
            message_id="msg_789",
            sent_at=datetime(2026, 1, 15, 3, 1, 30, tzinfo=timezone.utc),
            success=True,
        )
        assert notif.error is None
