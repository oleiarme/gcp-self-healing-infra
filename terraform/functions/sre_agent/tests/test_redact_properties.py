"""Property-based tests for redact.py using Hypothesis.

**Validates: Requirements 5.1, 5.2, 5.4**

Property 1: Redact removes all secret patterns — after redaction, no secret patterns
remain in the output.

Property 2: Redact is idempotent — redact(redact(s)) == redact(s) for any string s.

Property 8: Redact length bounded — len(redact(s)) ≤ len(s) + 1024 for any string s.
"""

import re

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from sre_agent.redact import SECRET_PATTERNS, redact


# Strategy: generate arbitrary text that may contain secret-like patterns
# We mix plain text with fragments that resemble secrets to stress the redaction logic.
_secret_fragments = st.sampled_from([
    "user@example.com",
    "Bearer abc123token",
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl",
    "postgres://admin:secret@db.host:5432/mydb",
    "password=SuperSecret123",
    'password="quoted secret"',
    "192.168.1.100",
    "[REDACTED_EMAIL]",
    "[REDACTED_TOKEN]",
    "[REDACTED_JWT]",
    "[REDACTED_CREDS]",
    "[REDACTED]",
    "[REDACTED_IP]",
    "Bearer [REDACTED_TOKEN]",
])

# Combine: either pure text, secret fragments, or a mix
_text_strategy = st.one_of(
    st.text(min_size=0, max_size=500),
    _secret_fragments,
    st.lists(
        st.one_of(st.text(min_size=0, max_size=100), _secret_fragments),
        min_size=1,
        max_size=5,
    ).map(" ".join),
)


@pytest.mark.property
class TestRedactIdempotentProperty:
    """Property 2: Redact is idempotent — redact(redact(s)) == redact(s)."""

    @given(s=_text_strategy)
    @settings(max_examples=300, deadline=None)
    def test_redact_idempotent(self, s: str):
        """**Validates: Requirements 5.2**

        For any string s, applying redact twice must yield the same result
        as applying it once. This ensures that redaction placeholders
        themselves are not further modified by subsequent redact calls.
        """
        once = redact(s)
        twice = redact(once)
        assert twice == once, (
            f"Idempotency violated:\n"
            f"  input:        {s!r}\n"
            f"  redact(s):    {once!r}\n"
            f"  redact²(s):   {twice!r}"
        )


# ─── Strategies for P1: generate strings containing secret patterns ────────────

# Email addresses
_email_user = st.from_regex(r"[a-zA-Z0-9][a-zA-Z0-9._%+\-]{0,20}", fullmatch=True)
_email_domain = st.from_regex(r"[a-zA-Z0-9][a-zA-Z0-9\-]{0,10}\.[a-zA-Z]{2,4}", fullmatch=True)
_emails = st.builds(lambda u, d: f"{u}@{d}", _email_user, _email_domain)

# Bearer tokens
_bearer_token_value = st.from_regex(r"[A-Za-z0-9_\-\.]{10,50}", fullmatch=True)
_bearer_tokens = st.builds(lambda t: f"Bearer {t}", _bearer_token_value)

# JWT tokens (three base64url segments starting with eyJ)
_jwt_segment = st.from_regex(r"[A-Za-z0-9_\-]{5,30}", fullmatch=True)
_jwts = st.builds(
    lambda s1, s2, s3: f"eyJ{s1}.{s2}.{s3}",
    _jwt_segment, _jwt_segment, _jwt_segment,
)

# Postgres URLs
_pg_user = st.from_regex(r"[a-zA-Z][a-zA-Z0-9]{1,10}", fullmatch=True)
_pg_pass = st.from_regex(r"[a-zA-Z0-9]{3,15}", fullmatch=True)
_pg_host = st.from_regex(r"[a-z][a-z0-9\-]{1,15}\.[a-z]{2,4}", fullmatch=True)
_pg_db = st.from_regex(r"[a-z][a-z0-9_]{1,10}", fullmatch=True)
_postgres_urls = st.builds(
    lambda u, p, h, d: f"postgres://{u}:{p}@{h}/{d}",
    _pg_user, _pg_pass, _pg_host, _pg_db,
)

# password=... patterns (unquoted and quoted)
_password_values = st.from_regex(r"[A-Za-z0-9]{3,20}", fullmatch=True)
_passwords_unquoted = st.builds(lambda v: f"password={v}", _password_values)
_passwords_quoted = st.builds(lambda v: f'password="{v}"', _password_values)

# Combine all secret-containing strategies
_secret_strings = st.one_of(
    _emails,
    _bearer_tokens,
    _jwts,
    _postgres_urls,
    _passwords_unquoted,
    _passwords_quoted,
)

# Context text that surrounds secrets
_context_text = st.from_regex(r"[a-zA-Z0-9 ,.:;\n]{0,50}", fullmatch=True)

# Full text: context + secret + context
_text_with_secret = st.builds(
    lambda pre, secret, post: f"{pre} {secret} {post}",
    _context_text, _secret_strings, _context_text,
)

# Multiple secrets in one string
_text_with_multiple_secrets = st.builds(
    lambda pre, s1, mid, s2, post: f"{pre} {s1} {mid} {s2} {post}",
    _context_text,
    _secret_strings,
    _context_text,
    _secret_strings,
    _context_text,
)


# ─── Redaction placeholder detection ──────────────────────────────────────────
# After redaction, patterns may still match their own replacement placeholders.
# For example, "Bearer [REDACTED_TOKEN]" matches the Bearer pattern because
# [REDACTED_TOKEN] is \S+. This is expected — the secret was removed.
# We detect this by checking if the matched text contains only known placeholder
# markers and no actual secret material.

_REDACTION_MARKERS = re.compile(
    r"\[REDACTED(?:_TOKEN|_JWT|_CREDS|_EMAIL|_IP)?\]"
)


def _contains_only_redacted_content(pattern: re.Pattern[str], match_text: str) -> bool:
    """Check if a pattern match contains only redaction placeholders, not real secrets.

    The approach: for each pattern, identify the "secret" capture group and verify
    it consists entirely of known redaction markers.
    """
    # Bearer pattern: group(0) is "Bearer <token>" — the token part should be placeholder
    if "Bearer" in pattern.pattern:
        # Extract the token part after "Bearer "
        bearer_match = re.match(r"Bearer\s+(.+)", match_text, re.IGNORECASE)
        if bearer_match:
            return bearer_match.group(1) == "[REDACTED_TOKEN]"
        return False

    # Postgres URL pattern: group(2) is the credentials part
    if "postgres" in pattern.pattern:
        pg_match = re.match(
            r"postgres(?:ql)?://(.+?)@", match_text, re.IGNORECASE
        )
        if pg_match:
            return pg_match.group(1) == "[REDACTED_CREDS]"
        return False

    # Password pattern: the value part should be [REDACTED]
    if "password" in pattern.pattern:
        pw_match = re.match(
            r'password\s*=\s*"?\[REDACTED\]"?', match_text, re.IGNORECASE
        )
        return pw_match is not None

    # Email pattern: the whole match should be the placeholder
    if "@" in pattern.pattern and "REDACTED_EMAIL" not in pattern.pattern:
        return match_text == "[REDACTED_EMAIL]"

    # JWT pattern: the whole match should be the placeholder
    if "eyJ" in pattern.pattern:
        return match_text == "[REDACTED_JWT]"

    return False


# ─── Property 1 Test ──────────────────────────────────────────────────────────


@pytest.mark.property
class TestRedactRemovesAllSecretPatterns:
    """Property 1: Redact removes all secret patterns.

    After redaction, no real secret patterns remain in the output.
    Redaction placeholders (e.g. "Bearer [REDACTED_TOKEN]") are acceptable
    since they prove the secret was removed.

    **Validates: Requirements 5.1**
    """

    @given(text=_text_with_secret)
    @settings(max_examples=300, deadline=None)
    def test_no_secret_pattern_remains_after_redact(self, text: str):
        """**Validates: Requirements 5.1**

        After redact(s), no real secret from SECRET_PATTERNS remains in the output.
        Generates strings containing a single secret pattern embedded in context text.
        Matches that are known redaction placeholders are excluded (they are the
        expected output of successful redaction).
        """
        result = redact(text)

        for pattern, _replacement in SECRET_PATTERNS:
            for match in pattern.finditer(result):
                matched_text = match.group()
                assert _contains_only_redacted_content(pattern, matched_text), (
                    f"Secret pattern still present after redaction!\n"
                    f"  Pattern: {pattern.pattern!r}\n"
                    f"  Match:   {matched_text!r}\n"
                    f"  Input:   {text!r}\n"
                    f"  Output:  {result!r}"
                )

    @given(text=_text_with_multiple_secrets)
    @settings(max_examples=200, deadline=None)
    def test_no_secret_pattern_remains_with_multiple_secrets(self, text: str):
        """**Validates: Requirements 5.1**

        Multiple secrets in one string are all removed after redaction.
        Matches that are known redaction placeholders are excluded.
        """
        result = redact(text)

        for pattern, _replacement in SECRET_PATTERNS:
            for match in pattern.finditer(result):
                matched_text = match.group()
                assert _contains_only_redacted_content(pattern, matched_text), (
                    f"Secret pattern still present after redaction!\n"
                    f"  Pattern: {pattern.pattern!r}\n"
                    f"  Match:   {matched_text!r}\n"
                    f"  Input:   {text!r}\n"
                    f"  Output:  {result!r}"
                )


# ─── Property 8 Test ──────────────────────────────────────────────────────────

# Strategy: arbitrary strings of varying lengths to stress the length bound
_arbitrary_text = st.text(min_size=0, max_size=5000)

# Mix of arbitrary text with embedded secret-like fragments
_text_with_potential_secrets = st.one_of(
    _arbitrary_text,
    _text_strategy,
    _text_with_secret,
    _text_with_multiple_secrets,
)


@pytest.mark.property
class TestRedactLengthBounded:
    """Property 8: Redact length bounded — len(redact(s)) ≤ len(s) + 1024.

    The redaction function must not expand the output by more than 1024 characters
    beyond the input length. This ensures that replacement placeholders do not
    cause unbounded growth.

    **Validates: Requirements 5.4**
    """

    @given(s=_text_with_potential_secrets)
    @settings(max_examples=500, deadline=None)
    def test_redact_length_bounded(self, s: str):
        """**Validates: Requirements 5.4**

        For any input string s, the length of redact(s) must not exceed
        len(s) + 1024. This bounds the overhead introduced by replacement
        placeholders.
        """
        result = redact(s)
        max_allowed = len(s) + 1024
        assert len(result) <= max_allowed, (
            f"Redact length bound violated!\n"
            f"  len(input):   {len(s)}\n"
            f"  len(output):  {len(result)}\n"
            f"  max allowed:  {max_allowed}\n"
            f"  overflow:     {len(result) - max_allowed}\n"
            f"  input[:200]:  {s[:200]!r}\n"
            f"  output[:200]: {result[:200]!r}"
        )
