"""Редакция секретов и PII перед отправкой в LLM.

Функции:
  - redact(text: str) -> str — удаление паттернов из SECRET_PATTERNS
  - redact_signals(signals: list[Signal]) -> list[Signal] — batch-редакция

Паттерны: email, Bearer token, JWT, postgres URL, password=..., IPv4 (опционально).

Requirements: 5.1, 5.2, 5.4, 5.5
"""

from __future__ import annotations

import re
from typing import Any

try:
    from .models import Signal
    from .settings import settings
except ImportError:
    from models import Signal  # type: ignore[no-redef]
    from settings import settings  # type: ignore[no-redef]


# ─── Secret pattern definitions ───────────────────────────────────────────────
# Each entry: (compiled_regex, replacement_string)
# Order matters: more specific patterns (JWT, Bearer) before generic (email).

SECRET_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # Bearer token: "Bearer <token>" → "Bearer [REDACTED_TOKEN]"
    (
        re.compile(r"(Bearer\s+)\S+", re.IGNORECASE),
        r"\1[REDACTED_TOKEN]",
    ),
    # JWT: three base64url segments separated by dots, starting with eyJ
    (
        re.compile(
            r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"
        ),
        "[REDACTED_JWT]",
    ),
    # Postgres/PostgreSQL URL: postgres(ql)://user:pass@host/db
    (
        re.compile(
            r"(postgres(?:ql)?://)([^@]+)(@)"
        ),
        r"\1[REDACTED_CREDS]\3",
    ),
    # password=... (with optional quotes)
    (
        re.compile(
            r'(password\s*=\s*)"[^"]*"',
            re.IGNORECASE,
        ),
        r"\1[REDACTED]",
    ),
    (
        re.compile(
            r"(password\s*=\s*)\S+",
            re.IGNORECASE,
        ),
        r"\1[REDACTED]",
    ),
    # Email: user@domain.tld
    (
        re.compile(
            r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"
        ),
        "[REDACTED_EMAIL]",
    ),
]

# IPv4 pattern — applied only when settings.redact_ipv4 is True
_IPV4_PATTERN = (
    re.compile(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)"),
    "[REDACTED_IP]",
)


def redact(text: str) -> str:
    """Remove all secret patterns from text.

    Applies SECRET_PATTERNS sequentially. When settings.redact_ipv4 is True,
    also redacts IPv4 addresses.

    Properties:
      - Idempotent: redact(redact(s)) == redact(s) (P2)
      - Length bounded: len(redact(s)) <= len(s) + 1024 (P8)

    Args:
        text: Input string potentially containing secrets.

    Returns:
        String with all matched secrets replaced by placeholders.
    """
    if not text:
        return text

    result = text
    for pattern, replacement in SECRET_PATTERNS:
        result = pattern.sub(replacement, result)

    # Optional IPv4 redaction
    if settings.redact_ipv4:
        pattern, replacement = _IPV4_PATTERN
        result = pattern.sub(replacement, result)

    return result


def _redact_value(value: Any) -> Any:
    """Recursively apply redact to string values in nested structures."""
    if isinstance(value, str):
        return redact(value)
    elif isinstance(value, list):
        return [_redact_value(item) for item in value]
    elif isinstance(value, dict):
        return {k: _redact_value(v) for k, v in value.items()}
    return value


def redact_signals(signals: list[Signal]) -> list[Signal]:
    """Apply redact to all text data in a list of Signals.

    Preserves Signal structure (kind, source) while redacting
    string content within data fields.

    Args:
        signals: List of Signal objects to redact.

    Returns:
        New list of Signal objects with redacted data.
    """
    result = []
    for signal in signals:
        redacted_data = _redact_value(signal.data)
        result.append(
            Signal(
                kind=signal.kind,
                source=signal.source,
                data=redacted_data,
            )
        )
    return result
