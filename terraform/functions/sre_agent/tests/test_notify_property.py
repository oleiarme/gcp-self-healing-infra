"""Property-based test for notify.py — Telegram message contains incident.id (P6).

**Validates: Requirements 3.2**

Property 6: Telegram message contains incident.id
  Formally: ∀ msg sent_to_telegram. incident.id ∈ msg.text

Every Telegram message sent by the SRE-agent MUST contain the incident.id
in the message body for traceability in Cloud Logging and Firestore.
"""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest
from hypothesis import given, settings as hyp_settings
from hypothesis import strategies as st

from sre_agent.models import Diagnosis, Incident
from sre_agent.notify import notify_telegram, notify_telegram_brief


# ---------------------------------------------------------------------------
# Strategies: generate arbitrary Incidents with known IDs
# ---------------------------------------------------------------------------

# Incident IDs: non-empty alphanumeric strings with dashes/underscores
_incident_ids = st.from_regex(r"[a-zA-Z0-9][a-zA-Z0-9_\-]{3,40}", fullmatch=True)

_kinds = st.sampled_from(["cpu", "mem", "pg_fatal", "n8n_error", "external_unreachable"])
_severities = st.sampled_from(["warning", "critical"])

_resource_vms = st.from_regex(r"[a-z][a-z0-9\-]{2,20}", fullmatch=True)
_resources = st.one_of(
    st.builds(lambda vm: {"vm": vm}, _resource_vms),
    st.builds(lambda h: {"public_host": h}, st.from_regex(r"[a-z][a-z0-9\-]{2,15}\.[a-z]{2,4}", fullmatch=True)),
)

_timestamps = st.datetimes(
    min_value=datetime(2024, 1, 1),
    max_value=datetime(2027, 12, 31),
    timezones=st.just(timezone.utc),
)

_incidents = st.builds(
    Incident,
    id=_incident_ids,
    kind=_kinds,
    severity=_severities,
    started_at=_timestamps,
    resource=_resources,
    raw_payload=st.just({"incident": {"incident_id": "placeholder"}}),
    source=st.just("cloud-monitoring"),
)

# Diagnosis strategies
_hypotheses = st.from_regex(r"[A-Za-z0-9 ,.\-:]{5,100}", fullmatch=True)
_suggested_fixes = st.from_regex(r"[A-Za-z0-9 ,.\-:]{5,80}", fullmatch=True)
_suggested_commands = st.one_of(
    st.none(),
    st.from_regex(r"[a-z][a-z0-9 \-_./]{5,50}", fullmatch=True),
)
_confidences = st.sampled_from(["low", "medium", "high"])
_models = st.sampled_from(["gemini-1.5-flash-002", "rule-based-v1", "claude-haiku"])

_diagnoses = st.builds(
    Diagnosis,
    hypothesis=_hypotheses,
    evidence_refs=st.just(["log:n8n:sample"]),
    confidence=_confidences,
    suggested_fix=_suggested_fixes,
    suggested_command=_suggested_commands,
    model=_models,
    tokens_in=st.integers(min_value=0, max_value=10000),
    tokens_out=st.integers(min_value=0, max_value=5000),
    cost_usd=st.floats(min_value=0.0, max_value=1.0),
    created_at=_timestamps,
)

# Suppression reasons for notify_telegram_brief
_suppression_reasons = st.sampled_from(["live_migration", "bootstrap_grace", "other_reason"])
_vm_ages = st.one_of(st.none(), st.integers(min_value=0, max_value=1800))


# ---------------------------------------------------------------------------
# Property 6: Telegram message contains incident.id
# ---------------------------------------------------------------------------


@pytest.mark.property
class TestTelegramMessageContainsIncidentId:
    """Property 6: Telegram message contains incident.id.

    **Validates: Requirements 3.2**

    Every Telegram message sent by notify_telegram and notify_telegram_brief
    MUST contain the incident.id in the text body for traceability.
    """

    @given(incident=_incidents, diagnosis=_diagnoses)
    @hyp_settings(max_examples=200, deadline=None)
    @patch("sre_agent.notify._send_telegram_message")
    def test_notify_telegram_contains_incident_id(
        self, mock_send: MagicMock, incident: Incident, diagnosis: Diagnosis
    ):
        """**Validates: Requirements 3.2**

        For any valid Incident with a non-empty id, notify_telegram sends a
        message that contains incident.id in the text body.
        """
        mock_send.return_value = {"ok": True, "result": {"message_id": 1}}

        notify_telegram(incident, diagnosis, "corr-test")

        mock_send.assert_called_once()
        text = mock_send.call_args[0][0]
        assert incident.id in text, (
            f"incident.id not found in Telegram message!\n"
            f"  incident.id: {incident.id!r}\n"
            f"  message text: {text[:500]!r}"
        )

    @given(incident=_incidents, reason=_suppression_reasons, vm_age=_vm_ages)
    @hyp_settings(max_examples=200, deadline=None)
    @patch("sre_agent.notify._send_telegram_message")
    def test_notify_telegram_brief_contains_incident_id(
        self, mock_send: MagicMock, incident: Incident, reason: str, vm_age
    ):
        """**Validates: Requirements 3.2**

        For any valid Incident with a non-empty id, notify_telegram_brief sends
        a message that contains incident.id in the text body.
        """
        mock_send.return_value = {"ok": True, "result": {"message_id": 1}}

        notify_telegram_brief(incident, reason, vm_age=vm_age)

        mock_send.assert_called_once()
        text = mock_send.call_args[0][0]
        assert incident.id in text, (
            f"incident.id not found in brief Telegram message!\n"
            f"  incident.id: {incident.id!r}\n"
            f"  reason: {reason!r}\n"
            f"  message text: {text[:500]!r}"
        )
