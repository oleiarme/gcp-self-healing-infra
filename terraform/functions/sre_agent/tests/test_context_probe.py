"""Unit tests for probe_external_reachability in context.py.

Validates: Requirements 2.6, 2.7, 2.8
"""

import socket
from unittest.mock import MagicMock, patch

import httpx
import pytest

from sre_agent.context import probe_external_reachability


class TestProbeExternalReachabilityAllSuccess:
    """Happy path: all four phases succeed."""

    @patch("sre_agent.context.httpx")
    @patch("sre_agent.context.socket")
    @patch("sre_agent.context.dns.resolver.resolve")
    def test_all_phases_succeed(self, mock_dns_resolve, mock_socket, mock_httpx):
        # DNS resolves
        mock_answer = MagicMock()
        mock_answer.__iter__ = lambda self: iter([MagicMock(address="1.2.3.4")])
        mock_dns_resolve.return_value = mock_answer

        # TCP connect succeeds
        mock_sock_instance = MagicMock()
        mock_socket.socket.return_value.__enter__ = MagicMock(return_value=mock_sock_instance)
        mock_socket.socket.return_value.__exit__ = MagicMock(return_value=False)

        # HTTPS root succeeds
        mock_root_response = MagicMock()
        mock_root_response.status_code = 200

        # HTTPS /healthz/deep succeeds
        mock_healthz_response = MagicMock()
        mock_healthz_response.status_code = 200

        mock_httpx.get.side_effect = [mock_root_response, mock_healthz_response]

        result = probe_external_reachability("example.com")

        assert isinstance(result, dict)
        assert result["dns_ok"] is True
        assert result["dns_ips"] == ["1.2.3.4"]
        assert result["dns_error"] is None
        assert result["tcp_ok"] is True
        assert result["tcp_error"] is None
        assert result["https_root_ok"] is True
        assert result["https_root_status"] == 200
        assert result["https_root_error"] is None
        assert result["healthz_ok"] is True
        assert result["healthz_status"] == 200
        assert result["healthz_error"] is None


class TestProbeExternalReachabilityDNSFailure:
    """Phase 1 (DNS) fails but subsequent phases still run."""

    @patch("sre_agent.context.httpx")
    @patch("sre_agent.context.socket")
    @patch("sre_agent.context.dns.resolver.resolve")
    def test_dns_failure_does_not_block_other_phases(
        self, mock_dns_resolve, mock_socket, mock_httpx
    ):
        # DNS fails
        mock_dns_resolve.side_effect = Exception("NXDOMAIN")

        # TCP connect succeeds (uses host directly when DNS fails)
        mock_sock_instance = MagicMock()
        mock_socket.socket.return_value.__enter__ = MagicMock(return_value=mock_sock_instance)
        mock_socket.socket.return_value.__exit__ = MagicMock(return_value=False)

        # HTTPS calls succeed
        mock_root_response = MagicMock()
        mock_root_response.status_code = 200
        mock_healthz_response = MagicMock()
        mock_healthz_response.status_code = 200
        mock_httpx.get.side_effect = [mock_root_response, mock_healthz_response]

        result = probe_external_reachability("example.com")

        assert result["dns_ok"] is False
        assert "NXDOMAIN" in result["dns_error"]
        assert result["dns_ips"] == []
        # Other phases still attempted
        assert result["tcp_ok"] is True
        assert result["https_root_ok"] is True
        assert result["healthz_ok"] is True


class TestProbeExternalReachabilityTCPFailure:
    """Phase 2 (TCP) fails but subsequent phases still run."""

    @patch("sre_agent.context.httpx")
    @patch("sre_agent.context.socket")
    @patch("sre_agent.context.dns.resolver.resolve")
    def test_tcp_failure_does_not_block_https(
        self, mock_dns_resolve, mock_socket, mock_httpx
    ):
        # DNS succeeds
        mock_answer = MagicMock()
        mock_answer.__iter__ = lambda self: iter([MagicMock(address="1.2.3.4")])
        mock_dns_resolve.return_value = mock_answer

        # TCP fails
        mock_sock_instance = MagicMock()
        mock_sock_instance.connect.side_effect = socket.timeout("Connection timed out")
        mock_socket.socket.return_value.__enter__ = MagicMock(return_value=mock_sock_instance)
        mock_socket.socket.return_value.__exit__ = MagicMock(return_value=False)

        # HTTPS calls succeed
        mock_root_response = MagicMock()
        mock_root_response.status_code = 200
        mock_healthz_response = MagicMock()
        mock_healthz_response.status_code = 200
        mock_httpx.get.side_effect = [mock_root_response, mock_healthz_response]

        result = probe_external_reachability("example.com")

        assert result["dns_ok"] is True
        assert result["tcp_ok"] is False
        assert "timed out" in result["tcp_error"].lower() or "Connection timed out" in result["tcp_error"]
        assert result["https_root_ok"] is True
        assert result["healthz_ok"] is True


class TestProbeExternalReachabilityHTTPSRootFailure:
    """Phase 3 (HTTPS root) fails but Phase 4 still runs."""

    @patch("sre_agent.context.httpx")
    @patch("sre_agent.context.socket")
    @patch("sre_agent.context.dns.resolver.resolve")
    def test_https_root_failure_does_not_block_healthz(
        self, mock_dns_resolve, mock_socket, mock_httpx
    ):
        # DNS succeeds
        mock_answer = MagicMock()
        mock_answer.__iter__ = lambda self: iter([MagicMock(address="1.2.3.4")])
        mock_dns_resolve.return_value = mock_answer

        # TCP succeeds
        mock_sock_instance = MagicMock()
        mock_socket.socket.return_value.__enter__ = MagicMock(return_value=mock_sock_instance)
        mock_socket.socket.return_value.__exit__ = MagicMock(return_value=False)

        # HTTPS root fails
        mock_httpx.get.side_effect = [
            httpx.ConnectTimeout("Connection timeout"),
            MagicMock(status_code=200),  # healthz succeeds
        ]

        result = probe_external_reachability("example.com")

        assert result["dns_ok"] is True
        assert result["tcp_ok"] is True
        assert result["https_root_ok"] is False
        assert result["https_root_status"] is None
        assert result["https_root_error"] is not None
        assert result["healthz_ok"] is True
        assert result["healthz_status"] == 200


class TestProbeExternalReachabilityHealthzFailure:
    """Phase 4 (/healthz/deep) fails."""

    @patch("sre_agent.context.httpx")
    @patch("sre_agent.context.socket")
    @patch("sre_agent.context.dns.resolver.resolve")
    def test_healthz_503(self, mock_dns_resolve, mock_socket, mock_httpx):
        # DNS succeeds
        mock_answer = MagicMock()
        mock_answer.__iter__ = lambda self: iter([MagicMock(address="1.2.3.4")])
        mock_dns_resolve.return_value = mock_answer

        # TCP succeeds
        mock_sock_instance = MagicMock()
        mock_socket.socket.return_value.__enter__ = MagicMock(return_value=mock_sock_instance)
        mock_socket.socket.return_value.__exit__ = MagicMock(return_value=False)

        # HTTPS root succeeds, healthz returns 503
        mock_root_response = MagicMock()
        mock_root_response.status_code = 200
        mock_healthz_response = MagicMock()
        mock_healthz_response.status_code = 503
        mock_httpx.get.side_effect = [mock_root_response, mock_healthz_response]

        result = probe_external_reachability("example.com")

        assert result["dns_ok"] is True
        assert result["tcp_ok"] is True
        assert result["https_root_ok"] is True
        assert result["healthz_ok"] is False
        assert result["healthz_status"] == 503
        assert result["healthz_error"] is None  # No exception, just non-2xx


class TestProbeExternalReachabilityAllFail:
    """All four phases fail — function still returns dict without raising."""

    @patch("sre_agent.context.httpx")
    @patch("sre_agent.context.socket")
    @patch("sre_agent.context.dns.resolver.resolve")
    def test_all_phases_fail(self, mock_dns_resolve, mock_socket, mock_httpx):
        # DNS fails
        mock_dns_resolve.side_effect = Exception("DNS timeout")

        # TCP fails
        mock_sock_instance = MagicMock()
        mock_sock_instance.connect.side_effect = socket.timeout("TCP timeout")
        mock_socket.socket.return_value.__enter__ = MagicMock(return_value=mock_sock_instance)
        mock_socket.socket.return_value.__exit__ = MagicMock(return_value=False)

        # HTTPS calls fail
        mock_httpx.get.side_effect = [
            httpx.ConnectTimeout("HTTPS root timeout"),
            httpx.ConnectTimeout("Healthz timeout"),
        ]

        result = probe_external_reachability("example.com")

        assert isinstance(result, dict)
        assert result["dns_ok"] is False
        assert result["dns_error"] is not None
        assert result["dns_ips"] == []
        assert result["tcp_ok"] is False
        assert result["tcp_error"] is not None
        assert result["https_root_ok"] is False
        assert result["https_root_error"] is not None
        assert result["https_root_status"] is None
        assert result["healthz_ok"] is False
        assert result["healthz_error"] is not None
        assert result["healthz_status"] is None


class TestProbeExternalReachabilityReturnStructure:
    """Validates that the function always returns a dict with all expected keys."""

    @patch("sre_agent.context.httpx")
    @patch("sre_agent.context.socket")
    @patch("sre_agent.context.dns.resolver.resolve")
    def test_all_keys_present(self, mock_dns_resolve, mock_socket, mock_httpx):
        mock_dns_resolve.side_effect = Exception("fail")
        mock_sock_instance = MagicMock()
        mock_sock_instance.connect.side_effect = Exception("fail")
        mock_socket.socket.return_value.__enter__ = MagicMock(return_value=mock_sock_instance)
        mock_socket.socket.return_value.__exit__ = MagicMock(return_value=False)
        mock_httpx.get.side_effect = Exception("fail")

        result = probe_external_reachability("example.com")

        expected_keys = {
            "dns_ok", "dns_error", "dns_ips",
            "tcp_ok", "tcp_error",
            "https_root_ok", "https_root_status", "https_root_error",
            "healthz_ok", "healthz_status", "healthz_error",
        }
        assert set(result.keys()) == expected_keys

    @patch("sre_agent.context.httpx")
    @patch("sre_agent.context.socket")
    @patch("sre_agent.context.dns.resolver.resolve")
    def test_never_raises_exception(self, mock_dns_resolve, mock_socket, mock_httpx):
        """No matter what happens internally, the function returns a dict."""
        mock_dns_resolve.side_effect = RuntimeError("unexpected")
        mock_socket.socket.side_effect = RuntimeError("unexpected")
        mock_httpx.get.side_effect = RuntimeError("unexpected")

        # Should not raise
        result = probe_external_reachability("example.com")
        assert isinstance(result, dict)
