"""Unit tests for store.py — deduplication, budget tracking, persistence.

Validates: Requirements 4.1, 4.2, 10.1, 10.4

Tests cover:
  - is_duplicate: returns True when incident already seen within TTL
  - mark_seen: writes document to Firestore incidents collection
  - today_cost_usd: aggregates cost_usd from diagnoses for current UTC day
  - persist_diagnosis: writes diagnosis to diagnoses collection with TTL
  - persist_diagnosis_skipped: writes suppressed incident record
  - Graceful degradation: all functions handle Firestore unavailability
"""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch, PropertyMock

import pytest

from sre_agent.models import Diagnosis, Incident


# --- Helpers ---


def _make_incident(
    incident_id: str = "inc-test-001",
    kind: str = "cpu",
    started_at: datetime | None = None,
) -> Incident:
    """Build a minimal Incident for testing."""
    return Incident(
        id=incident_id,
        kind=kind,
        severity="warning",
        started_at=started_at or datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc),
        resource={"vm": "n8n-prod-abc1"},
        raw_payload={"incident": {"incident_id": incident_id}},
        source="cloud-monitoring",
    )


def _make_diagnosis(cost_usd: float = 0.05) -> Diagnosis:
    """Build a minimal Diagnosis for testing."""
    return Diagnosis(
        hypothesis="High CPU due to n8n workflow loop",
        evidence_refs=["log-entry-1", "metric-point-2"],
        confidence="medium",
        suggested_fix="Check n8n workflow execution history",
        suggested_command=None,
        model="gemini-1.5-flash-002",
        tokens_in=1000,
        tokens_out=200,
        cost_usd=cost_usd,
        created_at=datetime(2026, 6, 15, 10, 1, 0, tzinfo=timezone.utc),
    )


# --- Tests: is_duplicate ---


class TestIsDuplicate:
    """Req 4.1: Deduplication prevents repeated processing within TTL."""

    @patch("sre_agent.store._get_db")
    def test_returns_true_when_document_exists_and_not_expired(self, mock_get_db):
        """is_duplicate returns True when incident doc exists within TTL."""
        from sre_agent.store import is_duplicate

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        mock_doc_ref = MagicMock()
        mock_doc_snapshot = MagicMock()
        mock_doc_snapshot.exists = True
        mock_doc_snapshot.to_dict.return_value = {
            "seen_at": datetime(2026, 6, 15, 9, 30, 0, tzinfo=timezone.utc),
            "ttl_expires_at": datetime(2026, 6, 15, 10, 30, 0, tzinfo=timezone.utc),
        }
        mock_doc_ref.get.return_value = mock_doc_snapshot
        mock_db.collection.return_value.document.return_value = mock_doc_ref

        result = is_duplicate("inc-test-001")
        assert result is True

    @patch("sre_agent.store._get_db")
    def test_returns_false_when_document_does_not_exist(self, mock_get_db):
        """is_duplicate returns False when no incident doc exists."""
        from sre_agent.store import is_duplicate

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        mock_doc_ref = MagicMock()
        mock_doc_snapshot = MagicMock()
        mock_doc_snapshot.exists = False
        mock_doc_ref.get.return_value = mock_doc_snapshot
        mock_db.collection.return_value.document.return_value = mock_doc_ref

        result = is_duplicate("inc-new-001")
        assert result is False

    @patch("sre_agent.store._utcnow")
    @patch("sre_agent.store._get_db")
    def test_returns_false_when_ttl_expired(self, mock_get_db, mock_utcnow):
        """is_duplicate returns False when document TTL has expired."""
        from sre_agent.store import is_duplicate

        # Set "now" to after the TTL expiry
        mock_utcnow.return_value = datetime(2026, 6, 15, 10, 0, 0, tzinfo=timezone.utc)

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        mock_doc_ref = MagicMock()
        mock_doc_snapshot = MagicMock()
        mock_doc_snapshot.exists = True
        mock_doc_snapshot.to_dict.return_value = {
            "seen_at": datetime(2026, 6, 15, 8, 0, 0, tzinfo=timezone.utc),
            "ttl_expires_at": datetime(2026, 6, 15, 9, 0, 0, tzinfo=timezone.utc),
        }
        mock_doc_ref.get.return_value = mock_doc_snapshot
        mock_db.collection.return_value.document.return_value = mock_doc_ref

        result = is_duplicate("inc-expired-001")
        assert result is False

    @patch("sre_agent.store._get_db")
    def test_graceful_degradation_on_firestore_error(self, mock_get_db):
        """Req 10.1: Returns False on Firestore unavailability (allow processing)."""
        from sre_agent.store import is_duplicate

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_db.collection.return_value.document.return_value.get.side_effect = Exception(
            "Firestore unavailable"
        )

        result = is_duplicate("inc-test-001")
        assert result is False


# --- Tests: mark_seen ---


class TestMarkSeen:
    """Req 4.1: mark_seen writes dedup document to Firestore."""

    @patch("sre_agent.store._get_db")
    def test_writes_document_with_ttl(self, mock_get_db):
        """mark_seen creates document with seen_at and ttl_expires_at."""
        from sre_agent.store import mark_seen

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_doc_ref = MagicMock()
        mock_db.collection.return_value.document.return_value = mock_doc_ref

        mark_seen("inc-test-001", ttl_seconds=3600)

        mock_db.collection.assert_called_with("incidents")
        mock_db.collection.return_value.document.assert_called_with("inc-test-001")
        mock_doc_ref.set.assert_called_once()

        call_data = mock_doc_ref.set.call_args[0][0]
        assert "seen_at" in call_data
        assert "ttl_expires_at" in call_data

    @patch("sre_agent.store._get_db")
    def test_graceful_degradation_on_firestore_error(self, mock_get_db):
        """Req 10.1: mark_seen does not raise on Firestore error."""
        from sre_agent.store import mark_seen

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_db.collection.return_value.document.return_value.set.side_effect = Exception(
            "Firestore unavailable"
        )

        # Should not raise
        mark_seen("inc-test-001", ttl_seconds=3600)


# --- Tests: today_cost_usd ---


class TestTodayCostUsd:
    """Req 4.2: today_cost_usd aggregates LLM cost for current UTC day."""

    @patch("sre_agent.store._get_db")
    def test_returns_sum_of_cost_usd_for_today(self, mock_get_db):
        """Aggregates cost_usd from all diagnoses created today."""
        from sre_agent.store import today_cost_usd

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        # Simulate two diagnosis documents with costs
        mock_doc1 = MagicMock()
        mock_doc1.to_dict.return_value = {"cost_usd": 0.50}
        mock_doc2 = MagicMock()
        mock_doc2.to_dict.return_value = {"cost_usd": 0.75}

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([mock_doc1, mock_doc2])
        mock_db.collection.return_value.where.return_value.where.return_value = mock_query

        result = today_cost_usd()
        assert result == pytest.approx(1.25)

    @patch("sre_agent.store._get_db")
    def test_returns_zero_when_no_diagnoses_today(self, mock_get_db):
        """Returns 0.0 when no diagnoses exist for today."""
        from sre_agent.store import today_cost_usd

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        mock_query = MagicMock()
        mock_query.stream.return_value = iter([])
        mock_db.collection.return_value.where.return_value.where.return_value = mock_query

        result = today_cost_usd()
        assert result == 0.0

    @patch("sre_agent.store._get_db")
    def test_graceful_degradation_returns_budget_on_firestore_error(self, mock_get_db):
        """Req 10.4: Returns budget value on Firestore error (conservative path)."""
        from sre_agent.store import today_cost_usd

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_db.collection.return_value.where.side_effect = Exception(
            "Firestore unavailable"
        )

        # Should return budget value to trigger rule-based fallback
        result = today_cost_usd()
        assert result >= 2.0  # At least the default budget


# --- Tests: persist_diagnosis ---


class TestPersistDiagnosis:
    """Req 4.1: persist_diagnosis writes to diagnoses collection."""

    @patch("sre_agent.store._get_db")
    def test_writes_diagnosis_with_correlation_id(self, mock_get_db):
        """Writes diagnosis document with all fields and correlation_id."""
        from sre_agent.store import persist_diagnosis

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_collection = MagicMock()
        mock_db.collection.return_value = mock_collection

        diagnosis = _make_diagnosis(cost_usd=0.05)
        persist_diagnosis(diagnosis, correlation_id="corr-123")

        mock_db.collection.assert_called_with("diagnoses")
        mock_collection.add.assert_called_once()

        call_data = mock_collection.add.call_args[0][0]
        assert call_data["cost_usd"] == 0.05
        assert call_data["correlation_id"] == "corr-123"
        assert call_data["hypothesis"] == "High CPU due to n8n workflow loop"
        assert "ttl_expires_at" in call_data

    @patch("sre_agent.store._get_db")
    def test_sets_ttl_30_days(self, mock_get_db):
        """TTL for diagnosis documents is 30 days."""
        from sre_agent.store import persist_diagnosis

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_collection = MagicMock()
        mock_db.collection.return_value = mock_collection

        diagnosis = _make_diagnosis()
        persist_diagnosis(diagnosis, correlation_id="corr-123")

        call_data = mock_collection.add.call_args[0][0]
        ttl = call_data["ttl_expires_at"]
        created = call_data["created_at"]
        delta = (ttl - created).days
        assert delta == 30

    @patch("sre_agent.store._get_db")
    def test_graceful_degradation_on_firestore_error(self, mock_get_db):
        """Req 10.1: Does not raise on Firestore error."""
        from sre_agent.store import persist_diagnosis

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_db.collection.return_value.add.side_effect = Exception(
            "Firestore unavailable"
        )

        diagnosis = _make_diagnosis()
        # Should not raise
        persist_diagnosis(diagnosis, correlation_id="corr-123")


# --- Tests: persist_diagnosis_skipped ---


class TestPersistDiagnosisSkipped:
    """persist_diagnosis_skipped records suppressed incidents."""

    @patch("sre_agent.store._get_db")
    def test_writes_skipped_record_with_reason(self, mock_get_db):
        """Writes suppressed incident with reason to Firestore."""
        from sre_agent.store import persist_diagnosis_skipped

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_collection = MagicMock()
        mock_db.collection.return_value = mock_collection

        incident = _make_incident()
        persist_diagnosis_skipped(incident, reason="live_migration")

        mock_db.collection.assert_called_with("diagnoses_skipped")
        mock_collection.add.assert_called_once()

        call_data = mock_collection.add.call_args[0][0]
        assert call_data["incident_id"] == "inc-test-001"
        assert call_data["reason"] == "live_migration"
        assert call_data["kind"] == "cpu"

    @patch("sre_agent.store._get_db")
    def test_graceful_degradation_on_firestore_error(self, mock_get_db):
        """Req 10.1: Does not raise on Firestore error."""
        from sre_agent.store import persist_diagnosis_skipped

        mock_db = MagicMock()
        mock_get_db.return_value = mock_db
        mock_db.collection.return_value.add.side_effect = Exception(
            "Firestore unavailable"
        )

        incident = _make_incident()
        # Should not raise
        persist_diagnosis_skipped(incident, reason="bootstrap_grace")
