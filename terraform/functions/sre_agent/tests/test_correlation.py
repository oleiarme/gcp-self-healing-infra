"""Unit tests for store.py — find_or_create_incident_window correlation.

Validates: Requirements 9.1, 9.5

Tests cover:
  - New window creation when no matching window exists
  - Same-kind correlation within 90s window
  - Cross-kind correlation within 180s window
  - Window expiry after 30 minutes
  - Priority matrix: pg_fatal > mem > cpu > external_unreachable > n8n_error
  - Severity upgrade when higher-priority signal arrives
  - Atomic Firestore Transaction usage
  - Graceful degradation on Firestore errors
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest

from sre_agent.models import Incident


# --- Helpers ---


def _make_incident(
    incident_id: str = "inc-test-001",
    kind: str = "cpu",
    severity: str = "warning",
    started_at: datetime | None = None,
    resource: dict | None = None,
) -> Incident:
    """Build a minimal Incident for testing."""
    return Incident(
        id=incident_id,
        kind=kind,
        severity=severity,
        started_at=started_at or datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc),
        resource=resource or {"vm": "n8n-prod-abc1"},
        raw_payload={"incident": {"incident_id": incident_id}},
        source="cloud-monitoring",
    )



# --- Tests: find_or_create_incident_window ---


class TestFindOrCreateIncidentWindowNewWindow:
    """When no matching window exists, a new window document is created."""

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_creates_new_window_when_no_existing_window(self, mock_get_db, mock_utcnow):
        """Creates new window and returns (window_id, correlated=False)."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # No existing windows found
        mock_query = MagicMock()
        mock_query.stream.return_value = iter([])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        # Mock document creation
        mock_doc_ref = MagicMock()
        mock_doc_ref.id = "window-new-001"
        mock_db.collection.return_value.add.return_value = (None, mock_doc_ref)

        incident = _make_incident(kind="cpu", severity="warning")
        window_id, correlated = find_or_create_incident_window(incident)

        assert window_id == "window-new-001"
        assert correlated is False

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_new_window_has_correct_fields(self, mock_get_db, mock_utcnow):
        """New window document contains primary_kind, resource_key, opened_at, etc."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        mock_doc_ref = MagicMock()
        mock_doc_ref.id = "window-new-002"
        mock_db.collection.return_value.add.return_value = (None, mock_doc_ref)

        incident = _make_incident(
            incident_id="inc-pg-001",
            kind="pg_fatal",
            severity="critical",
            resource={"vm": "n8n-prod-abc1"},
        )
        find_or_create_incident_window(incident)

        call_data = mock_db.collection.return_value.add.call_args[0][0]
        assert call_data["primary_kind"] == "pg_fatal"
        assert call_data["resource_key"] == "n8n-prod-abc1"
        assert call_data["opened_at"] == now
        assert call_data["last_signal_at"] == incident.started_at
        assert call_data["co_signals"] == []
        assert call_data["incident_ids"] == ["inc-pg-001"]
        assert call_data["severity"] == "critical"


class TestFindOrCreateIncidentWindowSameKind:
    """Same-kind correlation: incident.kind == window.primary_kind, window ≤ 90s."""

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_correlates_same_kind_within_90s(self, mock_get_db, mock_utcnow):
        """Same-kind signal within 90s correlates into existing window."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 1, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # Existing window: opened 30s ago, same kind "cpu", last_signal 30s ago
        window_opened = now - timedelta(seconds=30)
        window_last_signal = now - timedelta(seconds=30)
        mock_window_doc = MagicMock()
        mock_window_doc.id = "window-existing-001"
        mock_window_doc.to_dict.return_value = {
            "primary_kind": "cpu",
            "resource_key": "n8n-prod-abc1",
            "opened_at": window_opened,
            "last_signal_at": window_last_signal,
            "co_signals": [],
            "incident_ids": ["inc-first-001"],
            "severity": "warning",
        }

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        # Mock transaction
        mock_transaction = MagicMock()
        mock_db.transaction.return_value = mock_transaction

        incident = _make_incident(
            incident_id="inc-cpu-002",
            kind="cpu",
            severity="warning",
            started_at=now,  # gap = now - (now - 30s) = 30s < 90s
            resource={"vm": "n8n-prod-abc1"},
        )
        window_id, correlated = find_or_create_incident_window(incident)

        assert window_id == "window-existing-001"
        assert correlated is True

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_does_not_correlate_same_kind_beyond_90s(self, mock_get_db, mock_utcnow):
        """Same-kind signal beyond 90s from last_signal creates new window."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 2, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # Existing window: last_signal was 100s before incident.started_at
        window_opened = now - timedelta(seconds=120)
        window_last_signal = now - timedelta(seconds=100)
        mock_window_doc = MagicMock()
        mock_window_doc.id = "window-old-001"
        mock_window_doc.to_dict.return_value = {
            "primary_kind": "cpu",
            "resource_key": "n8n-prod-abc1",
            "opened_at": window_opened,
            "last_signal_at": window_last_signal,
            "co_signals": [],
            "incident_ids": ["inc-first-001"],
            "severity": "warning",
        }

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        # New window creation
        mock_doc_ref = MagicMock()
        mock_doc_ref.id = "window-new-003"
        mock_db.collection.return_value.add.return_value = (None, mock_doc_ref)

        incident = _make_incident(
            incident_id="inc-cpu-003",
            kind="cpu",
            severity="warning",
            started_at=now,  # gap = now - (now - 100s) = 100s > 90s
            resource={"vm": "n8n-prod-abc1"},
        )
        window_id, correlated = find_or_create_incident_window(incident)

        assert window_id == "window-new-003"
        assert correlated is False


class TestFindOrCreateIncidentWindowCrossKind:
    """Cross-kind correlation: incident.kind != window.primary_kind, window ≤ 180s."""

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_correlates_cross_kind_within_180s(self, mock_get_db, mock_utcnow):
        """Cross-kind signal within 180s correlates into existing window."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 2, 30, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # Existing window: primary_kind="pg_fatal", last_signal 120s ago
        window_opened = now - timedelta(seconds=150)
        window_last_signal = now - timedelta(seconds=120)
        mock_window_doc = MagicMock()
        mock_window_doc.id = "window-pg-001"
        mock_window_doc.to_dict.return_value = {
            "primary_kind": "pg_fatal",
            "resource_key": "n8n-prod-abc1",
            "opened_at": window_opened,
            "last_signal_at": window_last_signal,
            "co_signals": [],
            "incident_ids": ["inc-pg-001"],
            "severity": "critical",
        }

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        # Mock transaction
        mock_transaction = MagicMock()
        mock_db.transaction.return_value = mock_transaction

        # n8n_error arrives 120s after pg_fatal — within 180s cross-kind window
        incident = _make_incident(
            incident_id="inc-n8n-001",
            kind="n8n_error",
            severity="warning",
            started_at=now,  # gap = now - (now - 120s) = 120s < 180s
            resource={"vm": "n8n-prod-abc1"},
        )
        window_id, correlated = find_or_create_incident_window(incident)

        assert window_id == "window-pg-001"
        assert correlated is True

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_does_not_correlate_cross_kind_beyond_180s(self, mock_get_db, mock_utcnow):
        """Cross-kind signal beyond 180s from last_signal creates new window."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 5, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # Existing window: last_signal was 200s before incident.started_at
        window_opened = now - timedelta(seconds=300)
        window_last_signal = now - timedelta(seconds=200)
        mock_window_doc = MagicMock()
        mock_window_doc.id = "window-old-pg-001"
        mock_window_doc.to_dict.return_value = {
            "primary_kind": "pg_fatal",
            "resource_key": "n8n-prod-abc1",
            "opened_at": window_opened,
            "last_signal_at": window_last_signal,
            "co_signals": [],
            "incident_ids": ["inc-pg-001"],
            "severity": "critical",
        }

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        # New window creation
        mock_doc_ref = MagicMock()
        mock_doc_ref.id = "window-new-n8n-001"
        mock_db.collection.return_value.add.return_value = (None, mock_doc_ref)

        incident = _make_incident(
            incident_id="inc-n8n-002",
            kind="n8n_error",
            severity="warning",
            started_at=now,  # gap = now - (now - 200s) = 200s > 180s
            resource={"vm": "n8n-prod-abc1"},
        )
        window_id, correlated = find_or_create_incident_window(incident)

        assert window_id == "window-new-n8n-001"
        assert correlated is False


class TestFindOrCreateIncidentWindowExpiry:
    """Window expires after 30 minutes from opened_at."""

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_expired_window_not_matched(self, mock_get_db, mock_utcnow):
        """Window older than 30 minutes is not matched even if last_signal is recent."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 35, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # Window opened 31 minutes ago — expired
        window_opened = now - timedelta(minutes=31)
        window_last_signal = now - timedelta(seconds=30)
        mock_window_doc = MagicMock()
        mock_window_doc.id = "window-expired-001"
        mock_window_doc.to_dict.return_value = {
            "primary_kind": "cpu",
            "resource_key": "n8n-prod-abc1",
            "opened_at": window_opened,
            "last_signal_at": window_last_signal,
            "co_signals": [],
            "incident_ids": ["inc-first-001"],
            "severity": "warning",
        }

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        # New window creation
        mock_doc_ref = MagicMock()
        mock_doc_ref.id = "window-new-004"
        mock_db.collection.return_value.add.return_value = (None, mock_doc_ref)

        incident = _make_incident(
            incident_id="inc-cpu-004",
            kind="cpu",
            severity="warning",
            started_at=now,
            resource={"vm": "n8n-prod-abc1"},
        )
        window_id, correlated = find_or_create_incident_window(incident)

        assert window_id == "window-new-004"
        assert correlated is False


class TestFindOrCreateIncidentWindowPriorityMatrix:
    """Priority matrix: pg_fatal > mem > cpu > external_unreachable > n8n_error."""

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_severity_upgraded_when_higher_priority_signal_arrives(
        self, mock_get_db, mock_utcnow
    ):
        """When pg_fatal arrives into a cpu window, severity is upgraded."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 1, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # Existing window: primary_kind="cpu", severity="warning"
        window_opened = now - timedelta(seconds=30)
        window_last_signal = now - timedelta(seconds=30)
        mock_window_doc = MagicMock()
        mock_window_doc.id = "window-cpu-001"
        mock_window_doc.to_dict.return_value = {
            "primary_kind": "cpu",
            "resource_key": "n8n-prod-abc1",
            "opened_at": window_opened,
            "last_signal_at": window_last_signal,
            "co_signals": [],
            "incident_ids": ["inc-cpu-001"],
            "severity": "warning",
        }

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        # Mock transaction — @firestore.transactional calls the function with txn
        mock_transaction = MagicMock()
        mock_db.transaction.return_value = mock_transaction

        # pg_fatal arrives — higher priority than cpu (cross-kind, 30s gap < 180s)
        incident = _make_incident(
            incident_id="inc-pg-002",
            kind="pg_fatal",
            severity="critical",
            started_at=now,
            resource={"vm": "n8n-prod-abc1"},
        )
        window_id, correlated = find_or_create_incident_window(incident)

        assert window_id == "window-cpu-001"
        assert correlated is True

        # Verify the transaction update was called with severity upgrade
        mock_transaction.update.assert_called_once()
        update_args = mock_transaction.update.call_args
        update_data = update_args[0][1]
        assert update_data["severity"] == "critical"

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_severity_not_downgraded_when_lower_priority_signal_arrives(
        self, mock_get_db, mock_utcnow
    ):
        """When n8n_error arrives into a pg_fatal window, severity stays critical."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 1, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # Existing window: primary_kind="pg_fatal", severity="critical"
        window_opened = now - timedelta(seconds=30)
        window_last_signal = now - timedelta(seconds=30)
        mock_window_doc = MagicMock()
        mock_window_doc.id = "window-pg-002"
        mock_window_doc.to_dict.return_value = {
            "primary_kind": "pg_fatal",
            "resource_key": "n8n-prod-abc1",
            "opened_at": window_opened,
            "last_signal_at": window_last_signal,
            "co_signals": [],
            "incident_ids": ["inc-pg-001"],
            "severity": "critical",
        }

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        # Mock transaction
        mock_transaction = MagicMock()
        mock_db.transaction.return_value = mock_transaction

        # n8n_error arrives — lower priority than pg_fatal (cross-kind, 30s < 180s)
        incident = _make_incident(
            incident_id="inc-n8n-003",
            kind="n8n_error",
            severity="warning",
            started_at=now,
            resource={"vm": "n8n-prod-abc1"},
        )
        window_id, correlated = find_or_create_incident_window(incident)

        assert window_id == "window-pg-002"
        assert correlated is True

        # Verify severity was NOT updated (no downgrade)
        mock_transaction.update.assert_called_once()
        update_args = mock_transaction.update.call_args
        update_data = update_args[0][1]
        assert "severity" not in update_data


class TestFindOrCreateIncidentWindowResourceKey:
    """Resource key resolution: resource.vm or resource.public_host."""

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_uses_public_host_when_vm_not_present(self, mock_get_db, mock_utcnow):
        """Falls back to resource.public_host when resource.vm is absent."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        mock_doc_ref = MagicMock()
        mock_doc_ref.id = "window-host-001"
        mock_db.collection.return_value.add.return_value = (None, mock_doc_ref)

        incident = _make_incident(
            incident_id="inc-ext-001",
            kind="external_unreachable",
            severity="critical",
            resource={"public_host": "n8n.example.com"},
        )
        find_or_create_incident_window(incident)

        call_data = mock_db.collection.return_value.add.call_args[0][0]
        assert call_data["resource_key"] == "n8n.example.com"


class TestFindOrCreateIncidentWindowGracefulDegradation:
    """Graceful degradation on Firestore errors."""

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_returns_fallback_id_on_firestore_error(self, mock_get_db, mock_utcnow):
        """On Firestore error, returns a fallback window_id and correlated=False."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_db.collection.return_value.where.side_effect = Exception(
            "Firestore unavailable"
        )

        incident = _make_incident()
        window_id, correlated = find_or_create_incident_window(incident)

        # Should return a fallback ID (not crash)
        assert window_id is not None
        assert isinstance(window_id, str)
        assert window_id.startswith("fallback-")
        assert correlated is False


class TestFindOrCreateIncidentWindowTransaction:
    """Firestore Transaction is used for atomic updates."""

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_uses_firestore_transaction_for_update(self, mock_get_db, mock_utcnow):
        """Correlation update uses Firestore Transaction for atomicity."""
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 1, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # Existing window within correlation range
        window_opened = now - timedelta(seconds=30)
        window_last_signal = now - timedelta(seconds=30)
        mock_window_doc = MagicMock()
        mock_window_doc.id = "window-txn-001"
        mock_window_doc.to_dict.return_value = {
            "primary_kind": "cpu",
            "resource_key": "n8n-prod-abc1",
            "opened_at": window_opened,
            "last_signal_at": window_last_signal,
            "co_signals": [],
            "incident_ids": ["inc-first-001"],
            "severity": "warning",
        }

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        # Mock transaction
        mock_transaction = MagicMock()
        mock_db.transaction.return_value = mock_transaction

        incident = _make_incident(
            incident_id="inc-cpu-txn",
            kind="cpu",
            severity="warning",
            started_at=now,
            resource={"vm": "n8n-prod-abc1"},
        )
        find_or_create_incident_window(incident)

        # Verify transaction was created and used
        mock_db.transaction.assert_called_once()
        mock_transaction.update.assert_called_once()

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_transaction_update_contains_array_union(self, mock_get_db, mock_utcnow):
        """Transaction update uses ArrayUnion for co_signals and incident_ids."""
        from google.cloud.firestore_v1.transforms import ArrayUnion
        from sre_agent.store import find_or_create_incident_window

        now = datetime(2026, 6, 15, 10, 1, 0, tzinfo=timezone.utc)
        mock_utcnow.return_value = now

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        window_opened = now - timedelta(seconds=30)
        window_last_signal = now - timedelta(seconds=30)
        mock_window_doc = MagicMock()
        mock_window_doc.id = "window-arr-001"
        mock_window_doc.to_dict.return_value = {
            "primary_kind": "cpu",
            "resource_key": "n8n-prod-abc1",
            "opened_at": window_opened,
            "last_signal_at": window_last_signal,
            "co_signals": [],
            "incident_ids": ["inc-first-001"],
            "severity": "warning",
        }

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_window_doc])
        mock_db.collection.return_value.where.return_value.where.return_value.where.return_value = mock_query

        mock_transaction = MagicMock()
        mock_db.transaction.return_value = mock_transaction

        incident = _make_incident(
            incident_id="inc-mem-001",
            kind="mem",
            severity="critical",
            started_at=now,
            resource={"vm": "n8n-prod-abc1"},
        )
        find_or_create_incident_window(incident)

        # Verify update data contains ArrayUnion
        update_args = mock_transaction.update.call_args
        update_data = update_args[0][1]
        assert isinstance(update_data["co_signals"], ArrayUnion)
        assert isinstance(update_data["incident_ids"], ArrayUnion)
        assert update_data["last_signal_at"] == incident.started_at


class TestPriorityMatrix:
    """Test the priority ordering function directly."""

    def test_priority_ordering(self):
        """pg_fatal > mem > cpu > external_unreachable > n8n_error."""
        from sre_agent.store import _kind_priority

        assert _kind_priority("pg_fatal") > _kind_priority("mem")
        assert _kind_priority("mem") > _kind_priority("cpu")
        assert _kind_priority("cpu") > _kind_priority("external_unreachable")
        assert _kind_priority("external_unreachable") > _kind_priority("n8n_error")

    def test_unknown_kind_has_lowest_priority(self):
        """Unknown kinds get priority 0 (lowest)."""
        from sre_agent.store import _kind_priority

        assert _kind_priority("unknown_kind") == 0
        assert _kind_priority("n8n_error") > _kind_priority("unknown_kind")
