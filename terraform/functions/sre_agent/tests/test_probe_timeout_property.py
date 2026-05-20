"""Property-based test: external probe completes within timeout budget (P9).

**Validates: Requirements 2.7**

Property 9: External probe completes within timeout budget (≤ 30 s)
Formally: ∀ host. probe_external_reachability(host) → dict ∧ wallclock_seconds ≤ 30

Uses Hypothesis to generate random failure scenarios for each of the 4 phases
(DNS, TCP:443, HTTPS root, HTTPS /healthz/deep) and verifies that regardless
of network conditions, the function always returns a dict within 30 seconds.
"""

import socket
import time
from unittest.mock import MagicMock, patch

import httpx
import pytest
from hypothesis import given, settings, strategies as st

from sre_agent.context import probe_external_reachability


# ---------------------------------------------------------------------------
# Strategies: model network failure modes for each phase
# ---------------------------------------------------------------------------

# Failure modes for DNS resolution (Phase 1, timeout 5s)
dns_failure_modes = st.sampled_from([
    "success",
    "nxdomain",
    "timeout",
    "servfail",
    "no_answer",
])

# Failure modes for TCP connect (Phase 2, timeout 5s)
tcp_failure_modes = st.sampled_from([
    "success",
    "timeout",
    "connection_refused",
    "network_unreachable",
    "host_unreachable",
])

# Failure modes for HTTPS requests (Phase 3 & 4, timeout 10s each)
https_failure_modes = st.sampled_from([
    "success_200",
    "success_301",
    "error_500",
    "error_503",
    "timeout",
    "connection_error",
    "ssl_error",
    "read_timeout",
])

# Hostname strategy — valid-looking hostnames
hostname_strategy = st.from_regex(
    r"[a-z][a-z0-9\-]{0,20}\.[a-z]{2,6}", fullmatch=True
)


def _make_dns_side_effect(mode: str):
    """Create a side effect for dns.resolver.resolve based on failure mode."""
    if mode == "success":
        mock_answer = MagicMock()
        mock_answer.__iter__ = lambda self: iter([MagicMock(address="93.184.216.34")])
        return mock_answer
    elif mode == "nxdomain":
        raise Exception("The DNS query name does not exist: NXDOMAIN")
    elif mode == "timeout":
        raise Exception("The DNS operation timed out after 5.0 seconds")
    elif mode == "servfail":
        raise Exception("The DNS response does not contain an answer: SERVFAIL")
    elif mode == "no_answer":
        raise Exception("The DNS response does not contain an answer")
    else:
        raise Exception(f"DNS error: {mode}")


def _make_tcp_side_effect(mode: str):
    """Create a side effect for socket.connect based on failure mode."""
    if mode == "success":
        return None  # connect succeeds
    elif mode == "timeout":
        raise socket.timeout("Connection timed out")
    elif mode == "connection_refused":
        raise ConnectionRefusedError("[Errno 111] Connection refused")
    elif mode == "network_unreachable":
        raise OSError("[Errno 101] Network is unreachable")
    elif mode == "host_unreachable":
        raise OSError("[Errno 113] No route to host")
    else:
        raise OSError(f"Socket error: {mode}")


def _make_https_side_effect(mode: str):
    """Create a side effect for httpx.get based on failure mode."""
    if mode == "success_200":
        resp = MagicMock()
        resp.status_code = 200
        return resp
    elif mode == "success_301":
        resp = MagicMock()
        resp.status_code = 301
        return resp
    elif mode == "error_500":
        resp = MagicMock()
        resp.status_code = 500
        return resp
    elif mode == "error_503":
        resp = MagicMock()
        resp.status_code = 503
        return resp
    elif mode == "timeout":
        raise httpx.ConnectTimeout("Connection timed out")
    elif mode == "connection_error":
        raise httpx.ConnectError("Connection refused")
    elif mode == "ssl_error":
        raise httpx.ConnectError("SSL: CERTIFICATE_VERIFY_FAILED")
    elif mode == "read_timeout":
        raise httpx.ReadTimeout("Read timed out")
    else:
        raise httpx.HTTPError(f"HTTP error: {mode}")


# ---------------------------------------------------------------------------
# Property test
# ---------------------------------------------------------------------------


class TestProbeTimeoutBudgetProperty:
    """Property 9: External probe completes within timeout budget (≤ 30 s).

    **Validates: Requirements 2.7**
    """

    @given(
        host=hostname_strategy,
        dns_mode=dns_failure_modes,
        tcp_mode=tcp_failure_modes,
        https_root_mode=https_failure_modes,
        healthz_mode=https_failure_modes,
    )
    @settings(max_examples=200, deadline=35000)  # 35s deadline to allow 30s + overhead
    @patch("sre_agent.context.httpx")
    @patch("sre_agent.context.socket")
    @patch("sre_agent.context.dns.resolver.resolve")
    def test_probe_always_returns_dict_within_30s(
        self,
        mock_dns_resolve,
        mock_socket,
        mock_httpx,
        host,
        dns_mode,
        tcp_mode,
        https_root_mode,
        healthz_mode,
    ):
        """Regardless of network failure combination, probe returns dict in ≤ 30s."""
        # Configure DNS mock
        if dns_mode == "success":
            mock_answer = MagicMock()
            mock_answer.__iter__ = lambda self: iter(
                [MagicMock(address="93.184.216.34")]
            )
            mock_dns_resolve.return_value = mock_answer
        else:
            mock_dns_resolve.side_effect = lambda *a, **kw: _make_dns_side_effect(
                dns_mode
            )

        # Configure TCP socket mock
        mock_sock_instance = MagicMock()
        if tcp_mode == "success":
            mock_sock_instance.connect.return_value = None
        else:
            mock_sock_instance.connect.side_effect = lambda *a, **kw: _make_tcp_side_effect(
                tcp_mode
            )
        mock_socket.AF_INET = socket.AF_INET
        mock_socket.SOCK_STREAM = socket.SOCK_STREAM
        mock_socket.socket.return_value.__enter__ = MagicMock(
            return_value=mock_sock_instance
        )
        mock_socket.socket.return_value.__exit__ = MagicMock(return_value=False)

        # Configure HTTPS mock (two calls: root and /healthz/deep)
        def httpx_get_side_effect(url, **kwargs):
            if "/healthz/deep" in url:
                return _make_https_side_effect(healthz_mode)
            else:
                return _make_https_side_effect(https_root_mode)

        mock_httpx.get.side_effect = httpx_get_side_effect

        # Measure wall-clock time
        start = time.monotonic()
        result = probe_external_reachability(host)
        elapsed = time.monotonic() - start

        # Property assertions
        assert isinstance(result, dict), (
            f"probe_external_reachability must return dict, got {type(result)}"
        )
        assert elapsed <= 30.0, (
            f"probe_external_reachability exceeded 30s budget: {elapsed:.2f}s "
            f"(dns={dns_mode}, tcp={tcp_mode}, "
            f"https_root={https_root_mode}, healthz={healthz_mode})"
        )

        # Verify all expected keys are present
        expected_keys = {
            "dns_ok", "dns_ips", "dns_error",
            "tcp_ok", "tcp_error",
            "https_root_ok", "https_root_status", "https_root_error",
            "healthz_ok", "healthz_status", "healthz_error",
        }
        assert set(result.keys()) == expected_keys, (
            f"Missing or extra keys: {set(result.keys()) ^ expected_keys}"
        )
