"""Unit tests for alerts.py — parse_alert function.

Validates: Requirements 1.1–1.8
Tests cover:
  - Mapping policy_name → kind + severity for all 5 alert types
  - Validation of required fields (incident_id, policy_name)
  - Returns None for bad payloads
  - Deterministic parsing (same payload → same Incident)
  - Registry pattern (KIND_HANDLERS dict) for extensibility
  - Extraction of started_at, resource info, raw_payload
"""

from datetime import datetime, timezone

import pytest

from sre_agent.alerts import parse_alert, KIND_HANDLERS


# --- Helper: build a valid Cloud Monitoring payload ---


def _make_payload(
    incident_id: str = "inc-12345",
    policy_name: str = "vm_cpu_high",
    started_at: str = "2026-01-15T03:00:00Z",
    resource_name: str = "projects/my-proj/zones/us-central1-a/instances/n8n-prod-abc1",
    observed_time: str | None = None,
    extra_fields: dict | None = None,
) -> dict:
    """Build a minimal valid Cloud Monitoring alert payload."""
    payload = {
        "incident": {
            "incident_id": incident_id,
            "policy_name": policy_name,
            "started_at": started_at,
            "resource_name": resource_name,
            "resource": {
                "labels": {
                    "instance_id": "123456789",
                },
            },
        },
    }
    if observed_time:
        payload["incident"]["observed_time"] = observed_time
    if extra_fields:
        payload["incident"].update(extra_fields)
    return payload


# --- Tests: policy_name → kind + severity mapping ---


class TestPolicyMapping:
    """Req 1.1–1.5: Each policy_name maps to correct kind and severity."""

    def test_vm_cpu_high(self):
        """Req 1.1: vm_cpu_high → kind='cpu', severity='warning'."""
        payload = _make_payload(policy_name="vm_cpu_high")
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.kind == "cpu"
        assert incident.severity == "warning"

    def test_vm_memory_high(self):
        """Req 1.2: vm_memory_high → kind='mem', severity='critical'."""
        payload = _make_payload(policy_name="vm_memory_high")
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.kind == "mem"
        assert incident.severity == "critical"

    def test_postgres_fatal(self):
        """Req 1.3: postgres_fatal → kind='pg_fatal', severity='critical'."""
        payload = _make_payload(policy_name="postgres_fatal")
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.kind == "pg_fatal"
        assert incident.severity == "critical"

    def test_n8n_error_spike(self):
        """Req 1.4: n8n_error_spike → kind='n8n_error', severity='warning'."""
        payload = _make_payload(policy_name="n8n_error_spike")
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.kind == "n8n_error"
        assert incident.severity == "warning"

    def test_external_unreachable(self):
        """Req 1.5: external_unreachable → kind='external_unreachable', severity='critical'."""
        payload = _make_payload(policy_name="external_unreachable")
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.kind == "external_unreachable"
        assert incident.severity == "critical"

    def test_unknown_policy_returns_none(self):
        """Unknown policy_name → returns None (not in registry)."""
        payload = _make_payload(policy_name="unknown_policy_xyz")
        incident = parse_alert(payload)
        assert incident is None


# --- Tests: required field validation ---


class TestRequiredFieldValidation:
    """Req 1.7: Returns None when required fields are missing."""

    def test_missing_incident_key(self):
        """No 'incident' key at all → None."""
        payload = {"version": "1.0"}
        assert parse_alert(payload) is None

    def test_missing_incident_id(self):
        """Missing incident.incident_id → None."""
        payload = {
            "incident": {
                "policy_name": "vm_cpu_high",
                "started_at": "2026-01-15T03:00:00Z",
            }
        }
        assert parse_alert(payload) is None

    def test_missing_policy_name(self):
        """Missing incident.policy_name → None."""
        payload = {
            "incident": {
                "incident_id": "inc-123",
                "started_at": "2026-01-15T03:00:00Z",
            }
        }
        assert parse_alert(payload) is None

    def test_empty_incident_id(self):
        """Empty string incident_id → None."""
        payload = _make_payload(incident_id="")
        assert parse_alert(payload) is None

    def test_empty_policy_name(self):
        """Empty string policy_name → None."""
        payload = _make_payload(policy_name="")
        assert parse_alert(payload) is None

    def test_none_payload(self):
        """None payload → None (graceful handling)."""
        assert parse_alert(None) is None

    def test_empty_dict_payload(self):
        """Empty dict → None."""
        assert parse_alert({}) is None


# --- Tests: Incident fields extraction ---


class TestIncidentExtraction:
    """Correct extraction of id, started_at, resource, raw_payload, source."""

    def test_incident_id_extracted(self):
        """incident.id comes from payload incident.incident_id."""
        payload = _make_payload(incident_id="my-unique-id-42")
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.id == "my-unique-id-42"

    def test_started_at_from_started_at_field(self):
        """started_at parsed from incident.started_at."""
        payload = _make_payload(started_at="2026-06-15T10:30:00Z")
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.started_at == datetime(2026, 6, 15, 10, 30, 0, tzinfo=timezone.utc)

    def test_started_at_fallback_to_observed_time(self):
        """If started_at missing, use incident.observed_time."""
        payload = {
            "incident": {
                "incident_id": "inc-fallback",
                "policy_name": "vm_cpu_high",
                "observed_time": "2026-03-20T14:00:00Z",
                "resource_name": "projects/p/zones/z/instances/vm1",
            }
        }
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.started_at == datetime(2026, 3, 20, 14, 0, 0, tzinfo=timezone.utc)

    def test_resource_contains_vm_name(self):
        """resource dict contains vm name extracted from resource_name."""
        payload = _make_payload(
            resource_name="projects/my-proj/zones/us-central1-a/instances/n8n-prod-xyz"
        )
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.resource.get("vm") == "n8n-prod-xyz"

    def test_raw_payload_stored(self):
        """raw_payload contains the original payload dict."""
        payload = _make_payload()
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.raw_payload == payload

    def test_source_is_cloud_monitoring(self):
        """source field is always 'cloud-monitoring'."""
        payload = _make_payload()
        incident = parse_alert(payload)
        assert incident is not None
        assert incident.source == "cloud-monitoring"


# --- Tests: Deterministic parsing (P3) ---


class TestDeterminism:
    """Req 1.6 / P3: Same payload → same Incident."""

    def test_same_payload_same_result(self):
        """Calling parse_alert twice with same payload gives identical Incident."""
        payload = _make_payload(
            incident_id="det-test-001",
            policy_name="postgres_fatal",
            started_at="2026-01-15T03:00:00Z",
        )
        result1 = parse_alert(payload)
        result2 = parse_alert(payload)
        assert result1 is not None
        assert result2 is not None
        assert result1.id == result2.id
        assert result1.kind == result2.kind
        assert result1.severity == result2.severity
        assert result1.started_at == result2.started_at
        assert result1.resource == result2.resource
        assert result1.source == result2.source


# --- Tests: Registry pattern (Req 1.8) ---


class TestRegistryPattern:
    """Req 1.8: KIND_HANDLERS dict for extensibility."""

    def test_kind_handlers_is_dict(self):
        """KIND_HANDLERS is a dict mapping policy_name → handler."""
        assert isinstance(KIND_HANDLERS, dict)

    def test_kind_handlers_contains_all_5_policies(self):
        """All 5 MVP policy names are registered."""
        expected = {
            "vm_cpu_high",
            "vm_memory_high",
            "postgres_fatal",
            "n8n_error_spike",
            "external_unreachable",
        }
        assert expected.issubset(set(KIND_HANDLERS.keys()))

    def test_kind_handlers_values_are_callable(self):
        """Each handler in the registry is callable."""
        for name, handler in KIND_HANDLERS.items():
            assert callable(handler), f"Handler for '{name}' is not callable"
