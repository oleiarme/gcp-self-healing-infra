"""Property-based test: parse_alert is deterministic (P3).

**Validates: Requirements 1.6**

Property 3: For any valid payload, calling parse_alert twice produces
the same result. Formally: ∀ payload. parse_alert(payload) == parse_alert(payload)

Uses Hypothesis to generate arbitrary valid Cloud Monitoring alert payloads
and verifies that parse_alert is a pure, deterministic function.
"""

import pytest
from hypothesis import given, settings, strategies as st

from sre_agent.alerts import parse_alert, KIND_HANDLERS


# ---------------------------------------------------------------------------
# Strategies: generate valid Cloud Monitoring alert payloads
# ---------------------------------------------------------------------------

# Valid policy names from the KIND_HANDLERS registry
_VALID_POLICY_NAMES = list(KIND_HANDLERS.keys())

# Strategy for ISO-8601 timestamps (valid dates that parse_alert handles)
_timestamp_st = st.builds(
    lambda y, m, d, h, mi, s: f"{y:04d}-{m:02d}-{d:02d}T{h:02d}:{mi:02d}:{s:02d}Z",
    y=st.integers(min_value=2020, max_value=2030),
    m=st.integers(min_value=1, max_value=12),
    d=st.integers(min_value=1, max_value=28),  # 28 to avoid month-length issues
    h=st.integers(min_value=0, max_value=23),
    mi=st.integers(min_value=0, max_value=59),
    s=st.integers(min_value=0, max_value=59),
)

# Strategy for GCP resource_name paths
_resource_name_st = st.builds(
    lambda project, zone, instance: f"projects/{project}/zones/{zone}/instances/{instance}",
    project=st.from_regex(r"[a-z][a-z0-9\-]{3,20}", fullmatch=True),
    zone=st.sampled_from(["us-central1-a", "europe-west1-b", "asia-east1-c"]),
    instance=st.from_regex(r"[a-z][a-z0-9\-]{3,30}", fullmatch=True),
)

# Strategy for a valid alert payload that parse_alert will accept
_valid_payload_st = st.fixed_dictionaries({
    "incident": st.fixed_dictionaries({
        "incident_id": st.text(
            alphabet=st.characters(whitelist_categories=("L", "N", "P")),
            min_size=1,
            max_size=64,
        ),
        "policy_name": st.sampled_from(_VALID_POLICY_NAMES),
        "started_at": _timestamp_st,
        "resource_name": _resource_name_st,
        "resource": st.fixed_dictionaries({
            "labels": st.fixed_dictionaries({
                "instance_id": st.from_regex(r"[0-9]{6,18}", fullmatch=True),
            }),
        }),
    }),
})

# Strategy for arbitrary payloads (may or may not be valid)
_arbitrary_payload_st = st.one_of(
    _valid_payload_st,
    st.none(),
    st.dictionaries(st.text(max_size=10), st.text(max_size=10), max_size=5),
    st.just({}),
    st.just({"incident": {}}),
    st.just({"incident": {"incident_id": "x"}}),
    st.just({"incident": {"policy_name": "vm_cpu_high"}}),
    # Valid payload with unparseable timestamp (tests fallback determinism)
    st.fixed_dictionaries({
        "incident": st.fixed_dictionaries({
            "incident_id": st.text(
                alphabet=st.characters(whitelist_categories=("L", "N")),
                min_size=1,
                max_size=10,
            ),
            "policy_name": st.sampled_from(_VALID_POLICY_NAMES),
            "started_at": st.sampled_from([
                "not-a-date", "2020-00-00T00:00:00Z", "", "9999-99-99T99:99:99Z",
            ]),
            "resource_name": st.just("projects/p/zones/z/instances/vm1"),
            "resource": st.just({"labels": {"instance_id": "123"}}),
        }),
    }),
)


# ---------------------------------------------------------------------------
# Property test: determinism
# ---------------------------------------------------------------------------


@pytest.mark.property
class TestParseAlertDeterministic:
    """Property 3: parse_alert is deterministic.

    **Validates: Requirements 1.6**
    """

    @given(payload=_valid_payload_st)
    @settings(max_examples=200)
    def test_valid_payload_deterministic(self, payload):
        """For any valid payload, parse_alert(payload) == parse_alert(payload).

        Both calls must produce identical Incident objects with the same
        id, kind, severity, started_at, resource, and source fields.
        """
        result1 = parse_alert(payload)
        result2 = parse_alert(payload)

        # Both must return an Incident (not None) for valid payloads
        assert result1 is not None, "parse_alert returned None for valid payload"
        assert result2 is not None, "parse_alert returned None for valid payload (2nd call)"

        # Deep equality on all deterministic fields
        assert result1.id == result2.id
        assert result1.kind == result2.kind
        assert result1.severity == result2.severity
        assert result1.started_at == result2.started_at
        assert result1.resource == result2.resource
        assert result1.source == result2.source
        assert result1.raw_payload == result2.raw_payload

    @given(payload=_arbitrary_payload_st)
    @settings(max_examples=200)
    def test_arbitrary_payload_deterministic(self, payload):
        """For any payload (valid or invalid), two calls produce the same result.

        This covers the None-return path as well: if parse_alert returns None
        for a payload, it must always return None for that same payload.
        """
        result1 = parse_alert(payload)
        result2 = parse_alert(payload)

        # Both must be the same (either both None or both equal Incidents)
        if result1 is None:
            assert result2 is None
        else:
            assert result2 is not None
            assert result1.id == result2.id
            assert result1.kind == result2.kind
            assert result1.severity == result2.severity
            assert result1.started_at == result2.started_at
            assert result1.resource == result2.resource
            assert result1.source == result2.source
            assert result1.raw_payload == result2.raw_payload
