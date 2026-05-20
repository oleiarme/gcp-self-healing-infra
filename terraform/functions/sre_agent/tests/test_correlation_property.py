"""Property-based test: Correlation reduces LLM calls (P10).

**Validates: Requirements 9.1**

Property 10: Correlation reduces LLM calls within window (same-kind и cross-kind).

When multiple incidents of the same kind arrive within the correlation window (90s
for same-kind, 180s for cross-kind), they should be grouped into a single correlation
window and only trigger ONE LLM call instead of multiple.

The mechanism: `find_or_create_incident_window` returns `(window_id, correlated=True)`
for subsequent signals within the window. The main orchestrator (`sre_agent`) returns
"correlated" immediately without calling LLM when `correlated=True`.

Test approach:
  - Simulate two same-kind incidents arriving within 90s — verify grouping
  - Simulate two cross-kind incidents arriving within 180s — verify correlation
  - Verify that correlated incidents don't trigger separate LLM calls (via main.py)
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest
from hypothesis import given, settings as hyp_settings, assume
from hypothesis import strategies as st

from sre_agent.models import Incident


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

_KINDS = ["cpu", "mem", "pg_fatal", "n8n_error", "external_unreachable"]

_kind_strategy = st.sampled_from(_KINDS)

_resource_key_strategy = st.sampled_from([
    "n8n-prod-abc1",
    "n8n-prod-def2",
    "n8n-staging-xyz",
])


def _make_incident(
    incident_id: str,
    kind: str,
    started_at: datetime,
    resource_key: str = "n8n-prod-abc1",
) -> Incident:
    """Build a minimal Incident for testing."""
    severity = "critical" if kind in ("pg_fatal", "mem", "external_unreachable") else "warning"
    return Incident(
        id=incident_id,
        kind=kind,
        severity=severity,
        started_at=started_at,
        resource={"vm": resource_key},
        raw_payload={"incident": {"incident_id": incident_id}},
        source="cloud-monitoring",
    )


def _mock_firestore_with_window(window_data: dict | None, window_id: str = "window-001"):
    """Create a mock Firestore DB that returns the given window (or empty)."""
    mock_db = MagicMock()

    if window_data is not None:
        mock_window_doc = MagicMock()
        mock_window_doc.id = window_id
        mock_window_doc.to_dict.return_value = window_data
        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
    else:
        mock_query = MagicMock()
        mock_query.stream.return_value = iter([])

    mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

    # Mock for new window creation
    mock_doc_ref = MagicMock()
    mock_doc_ref.id = "window-new-001"
    mock_db.collection.return_value.add.return_value = (None, mock_doc_ref)

    # Mock transaction
    mock_transaction = MagicMock()
    mock_db.transaction.return_value = mock_transaction

    return mock_db


# ---------------------------------------------------------------------------
# Property 10: Same-kind correlation reduces LLM calls
# ---------------------------------------------------------------------------


class TestCorrelationReducesLLMCallsSameKind:
    """Same-kind incidents within 90s window trigger only ONE LLM call."""

    @given(
        kind=_kind_strategy,
        resource_key=_resource_key_strategy,
        gap_seconds=st.integers(min_value=1, max_value=89),
    )
    @hyp_settings(max_examples=50, deadline=None)
    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_same_kind_within_window_correlates(
        self, mock_get_db, mock_utcnow, kind, resource_key, gap_seconds
    ):
        """For any kind and any gap < 90s, second same-kind incident correlates.

        When correlated=True, the main loop returns "correlated" without LLM call.
        This means N same-kind incidents within 90s → only 1 LLM call (the first).
        """
        from sre_agent.store import find_or_create_incident_window

        base_time = datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc)
        now = base_time + timedelta(seconds=gap_seconds)
        mock_utcnow.return_value = now

        # Simulate existing window created by first incident
        window_data = {
            "primary_kind": kind,
            "resource_key": resource_key,
            "opened_at": base_time,
            "last_signal_at": base_time,
            "co_signals": [],
            "incident_ids": ["inc-first-001"],
            "severity": "warning",
        }
        mock_db = _mock_firestore_with_window(window_data)
        mock_get_db.return_value = mock_db

        # Second incident of same kind arrives within gap_seconds
        incident = _make_incident(
            incident_id="inc-second-002",
            kind=kind,
            started_at=now,
            resource_key=resource_key,
        )

        window_id, correlated = find_or_create_incident_window(incident)

        # Property: second signal is correlated (no separate LLM call)
        assert correlated is True, (
            f"Same-kind '{kind}' with gap={gap_seconds}s should correlate "
            f"(window=90s), but got correlated=False"
        )


# ---------------------------------------------------------------------------
# Property 10: Cross-kind correlation reduces LLM calls
# ---------------------------------------------------------------------------


class TestCorrelationReducesLLMCallsCrossKind:
    """Cross-kind incidents within 180s window trigger only ONE LLM call."""

    @given(
        primary_kind=_kind_strategy,
        secondary_kind=_kind_strategy,
        resource_key=_resource_key_strategy,
        gap_seconds=st.integers(min_value=1, max_value=179),
    )
    @hyp_settings(max_examples=50, deadline=None)
    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_cross_kind_within_window_correlates(
        self, mock_get_db, mock_utcnow, primary_kind, secondary_kind, resource_key, gap_seconds
    ):
        """For any two different kinds and any gap < 180s, second incident correlates.

        Cross-kind cascade (e.g. pg_fatal → n8n_error after connection pool timeout)
        should be grouped into one window → one LLM call.
        """
        from sre_agent.store import find_or_create_incident_window

        # Ensure cross-kind (different kinds)
        assume(primary_kind != secondary_kind)

        base_time = datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc)
        now = base_time + timedelta(seconds=gap_seconds)
        mock_utcnow.return_value = now

        # Simulate existing window created by first incident (primary_kind)
        window_data = {
            "primary_kind": primary_kind,
            "resource_key": resource_key,
            "opened_at": base_time,
            "last_signal_at": base_time,
            "co_signals": [],
            "incident_ids": ["inc-primary-001"],
            "severity": "critical",
        }
        mock_db = _mock_firestore_with_window(window_data)
        mock_get_db.return_value = mock_db

        # Second incident of different kind arrives within gap_seconds
        incident = _make_incident(
            incident_id="inc-secondary-002",
            kind=secondary_kind,
            started_at=now,
            resource_key=resource_key,
        )

        window_id, correlated = find_or_create_incident_window(incident)

        # Property: cross-kind signal is correlated (no separate LLM call)
        assert correlated is True, (
            f"Cross-kind '{primary_kind}' → '{secondary_kind}' with gap={gap_seconds}s "
            f"should correlate (window=180s), but got correlated=False"
        )


# ---------------------------------------------------------------------------
# Property 10: End-to-end — correlated incidents skip LLM in main loop
# ---------------------------------------------------------------------------


class TestCorrelatedIncidentSkipsLLM:
    """Verify that when correlation returns correlated=True, LLM is NOT called."""

    @given(
        kind=_kind_strategy,
        resource_key=_resource_key_strategy,
        gap_seconds=st.integers(min_value=1, max_value=89),
    )
    @hyp_settings(max_examples=30, deadline=None)
    @patch("sre_agent.main.persist_diagnosis")
    @patch("sre_agent.main.notify_telegram")
    @patch("sre_agent.main._process_with_timeout")
    @patch("sre_agent.main.find_or_create_incident_window")
    @patch("sre_agent.main.instance_age_seconds_cached")
    @patch("sre_agent.main.is_live_migration_in_window")
    @patch("sre_agent.main.mark_seen")
    @patch("sre_agent.main.is_duplicate")
    @patch("sre_agent.main.parse_alert")
    @patch("sre_agent.main._extract_payload")
    def test_correlated_incident_does_not_call_llm(
        self,
        mock_extract,
        mock_parse,
        mock_is_dup,
        mock_mark_seen,
        mock_is_live_mig,
        mock_instance_age,
        mock_find_window,
        mock_process,
        mock_notify,
        mock_persist,
        kind,
        resource_key,
        gap_seconds,
    ):
        """When find_or_create_incident_window returns correlated=True,
        the main function returns "correlated" without calling LLM/notify/persist.

        This proves that N correlated incidents → 0 additional LLM calls.
        """
        from sre_agent.main import sre_agent

        base_time = datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc)
        incident = _make_incident(
            incident_id=f"inc-{kind}-{gap_seconds}",
            kind=kind,
            started_at=base_time + timedelta(seconds=gap_seconds),
            resource_key=resource_key,
        )

        mock_extract.return_value = {"incident": {"incident_id": incident.id}}
        mock_parse.return_value = incident
        mock_is_dup.return_value = False
        mock_is_live_mig.return_value = False
        mock_instance_age.return_value = None  # No bootstrap grace
        mock_find_window.return_value = ("window-corr-001", True)  # correlated!

        cloud_event = MagicMock()
        result = sre_agent(cloud_event)

        # Property: returns "correlated" — no LLM call
        assert result == "correlated"

        # Property: LLM processing was NOT invoked
        mock_process.assert_not_called()

        # Property: Telegram notification was NOT sent
        mock_notify.assert_not_called()

        # Property: Diagnosis was NOT persisted
        mock_persist.assert_not_called()
