"""Unit tests for redact.py — secret pattern removal and signal redaction.

Validates: Requirements 5.1, 5.2, 5.4, 5.5
"""

import os
from unittest.mock import patch

import pytest

from sre_agent.models import Signal
from sre_agent.redact import SECRET_PATTERNS, redact, redact_signals


class TestRedactEmail:
    """Requirement 5.1: email addresses are redacted."""

    def test_simple_email(self):
        assert redact("contact user@example.com now") == "contact [REDACTED_EMAIL] now"

    def test_email_with_plus(self):
        assert "[REDACTED_EMAIL]" in redact("send to user+tag@domain.org")

    def test_email_with_subdomain(self):
        assert "[REDACTED_EMAIL]" in redact("admin@sub.domain.co.uk")

    def test_multiple_emails(self):
        text = "from a@b.com to c@d.org"
        result = redact(text)
        assert "a@b.com" not in result
        assert "c@d.org" not in result


class TestRedactBearerToken:
    """Requirement 5.1: Bearer tokens are redacted."""

    def test_bearer_token(self):
        text = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig"
        result = redact(text)
        assert "Bearer [REDACTED_TOKEN]" in result
        assert "eyJ" not in result

    def test_bearer_short_token(self):
        text = "Bearer abc123def456"
        result = redact(text)
        assert "Bearer [REDACTED_TOKEN]" in result
        assert "abc123def456" not in result


class TestRedactJWT:
    """Requirement 5.1: JWT tokens (eyJ...) are redacted."""

    def test_standalone_jwt(self):
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        result = redact(f"token={jwt}")
        assert "[REDACTED_JWT]" in result
        assert "eyJhbGciOiJIUzI1NiJ9" not in result

    def test_jwt_in_log_line(self):
        text = 'auth failed for token eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJhIn0.c2lnbmF0dXJl in request'
        result = redact(text)
        assert "[REDACTED_JWT]" in result
        assert "eyJhbGciOiJSUzI1NiJ9" not in result


class TestRedactPostgresURL:
    """Requirement 5.1: postgres connection URLs are redacted."""

    def test_postgres_url(self):
        text = "connecting to postgres://admin:s3cret@db.host.com:5432/mydb"
        result = redact(text)
        assert "admin" not in result
        assert "s3cret" not in result
        assert "[REDACTED_CREDS]" in result
        # Host should remain for diagnostics
        assert "db.host.com" in result

    def test_postgresql_url(self):
        text = "DSN=postgresql://user:pass@localhost/testdb"
        result = redact(text)
        assert "user:pass" not in result
        assert "[REDACTED_CREDS]" in result


class TestRedactPassword:
    """Requirement 5.1: password=... patterns are redacted."""

    def test_password_equals(self):
        text = "config password=SuperSecret123 loaded"
        result = redact(text)
        assert "SuperSecret123" not in result
        assert "password=[REDACTED]" in result

    def test_password_with_quotes(self):
        text = 'password="my secret pass"'
        result = redact(text)
        assert "my secret pass" not in result
        assert "password=[REDACTED]" in result


class TestRedactIPv4:
    """Requirement 5.5: IPv4 redaction is optional via REDACT_IPV4 env."""

    def test_ipv4_not_redacted_by_default(self):
        """When REDACT_IPV4 is false (default), IPs remain."""
        with patch("sre_agent.redact.settings") as mock_settings:
            mock_settings.redact_ipv4 = False
            # Need to reimport or call with current settings
            from sre_agent.redact import redact as _redact
            # Since settings is read at call time, we patch the module-level reference
        # The default behavior (settings.redact_ipv4 = False) should not redact IPs
        text = "connection from 192.168.1.100 refused"
        result = redact(text)
        # Default is False, so IP should remain
        assert "192.168.1.100" in result

    def test_ipv4_redacted_when_enabled(self):
        """When REDACT_IPV4 is true, IPs are redacted."""
        with patch("sre_agent.redact.settings") as mock_settings:
            mock_settings.redact_ipv4 = True
            from sre_agent.redact import redact as _redact
            result = _redact("connection from 192.168.1.100 refused")
            assert "192.168.1.100" not in result
            assert "[REDACTED_IP]" in result


class TestRedactIdempotent:
    """Requirement 5.2: redact(redact(s)) == redact(s)."""

    def test_idempotent_email(self):
        text = "user@example.com"
        once = redact(text)
        twice = redact(once)
        assert once == twice

    def test_idempotent_bearer(self):
        text = "Bearer eyJtoken123"
        once = redact(text)
        twice = redact(once)
        assert once == twice

    def test_idempotent_jwt(self):
        text = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"
        once = redact(text)
        twice = redact(once)
        assert once == twice

    def test_idempotent_postgres_url(self):
        text = "postgres://user:pass@host/db"
        once = redact(text)
        twice = redact(once)
        assert once == twice

    def test_idempotent_password(self):
        text = "password=secret123"
        once = redact(text)
        twice = redact(once)
        assert once == twice

    def test_idempotent_mixed(self):
        text = "user@x.com Bearer eyJabc.def.ghi password=foo postgres://u:p@h/d"
        once = redact(text)
        twice = redact(once)
        assert once == twice


class TestRedactLengthBounded:
    """Requirement 5.4: len(redact(s)) <= len(s) + 1024."""

    def test_short_string(self):
        text = "hello world"
        assert len(redact(text)) <= len(text) + 1024

    def test_string_with_secrets(self):
        text = "user@example.com Bearer eyJtoken password=secret"
        assert len(redact(text)) <= len(text) + 1024

    def test_empty_string(self):
        assert redact("") == ""
        assert len(redact("")) <= 0 + 1024


class TestRedactSignals:
    """Requirement 5.1: redact_signals applies redact to all text data in signals."""

    def test_redact_signals_list_data(self):
        signals = [
            Signal(
                kind="n8n_logs",
                source="n8n_logs",
                data=[
                    {"text": "error for user@example.com", "ts": "2026-01-01T00:00:00Z"},
                    {"text": "password=secret123 in config", "ts": "2026-01-01T00:01:00Z"},
                ],
            )
        ]
        result = redact_signals(signals)
        assert len(result) == 1
        # Check that secrets are removed from data
        for item in result[0].data:
            assert "user@example.com" not in str(item)
            assert "secret123" not in str(item)

    def test_redact_signals_dict_data(self):
        signals = [
            Signal(
                kind="external_probe",
                source="external_probe",
                data={"error": "auth failed for user@test.com", "dns_ok": True},
            )
        ]
        result = redact_signals(signals)
        assert len(result) == 1
        assert "user@test.com" not in str(result[0].data)

    def test_redact_signals_preserves_structure(self):
        """Signal kind, source should be preserved."""
        signals = [
            Signal(kind="n8n_logs", source="n8n_logs", data=[{"text": "clean data"}])
        ]
        result = redact_signals(signals)
        assert result[0].kind == "n8n_logs"
        assert result[0].source == "n8n_logs"

    def test_redact_signals_empty_list(self):
        assert redact_signals([]) == []


class TestSecretPatternsTable:
    """Verify SECRET_PATTERNS table exists and has expected entries."""

    def test_secret_patterns_is_list(self):
        assert isinstance(SECRET_PATTERNS, list)

    def test_secret_patterns_has_minimum_entries(self):
        # At least: email, bearer, jwt, postgres url, password
        assert len(SECRET_PATTERNS) >= 5
