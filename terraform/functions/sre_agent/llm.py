"""Pluggable LLM provider для анализа инцидентов.

Функции:
  - analyze_with_llm(incident, signals) -> Diagnosis
  - _call_gemini(system, user, model, timeout, api_key) — адаптер Google Gemini
  - _call_claude(system, user, model, timeout, api_key) — адаптер Anthropic Claude
  - _call_openai(system, user, model, timeout, api_key) — адаптер OpenAI

Переключение через settings.llm_provider без изменения сигнатуры.
Таймаут LLM_TIMEOUT_SECONDS (default 45 s).
Структурированный лог event=llm_call с tokens_in, tokens_out, cost_usd, provider, model.

Requirements: 13.1–13.6, 4.6, 11.4
"""

from __future__ import annotations

import json
import logging
import time
from datetime import datetime, timezone
from typing import TYPE_CHECKING

import httpx

from .prompts import SYSTEM_PROMPT, format_user_prompt
from .settings import settings

if TYPE_CHECKING:
    from .models import Diagnosis, Incident, Signal

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Cost tables ($ per 1M tokens) — from design.md
# ---------------------------------------------------------------------------

_COST_TABLE: dict[str, dict[str, float]] = {
    # model_prefix: {"input": $/1M, "output": $/1M}
    "gemini-1.5-flash": {"input": 0.075, "output": 0.30},
    "gemini-1.5-pro": {"input": 1.25, "output": 5.00},
    "gemini-2.0-flash": {"input": 0.075, "output": 0.30},
    "claude-3-haiku": {"input": 0.80, "output": 4.00},
    "claude-3.5-haiku": {"input": 0.80, "output": 4.00},
    "claude-3-sonnet": {"input": 3.00, "output": 15.00},
    "claude-3.5-sonnet": {"input": 3.00, "output": 15.00},
    "gpt-4o-mini": {"input": 0.15, "output": 0.60},
    "gpt-4o": {"input": 2.50, "output": 10.00},
}

# Default fallback pricing (conservative estimate)
_DEFAULT_COST = {"input": 1.00, "output": 4.00}


# ---------------------------------------------------------------------------
# Cost estimation
# ---------------------------------------------------------------------------


def _estimate_cost(usage: dict[str, int], model: str) -> float:
    """Estimate cost in USD based on token usage and model.

    Args:
        usage: Dict with 'input' and 'output' token counts.
        model: Model name string (e.g. 'gemini-1.5-flash-002').

    Returns:
        Estimated cost in USD.
    """
    # Find matching cost entry by prefix
    cost_entry = _DEFAULT_COST
    for prefix, entry in _COST_TABLE.items():
        if model.startswith(prefix):
            cost_entry = entry
            break

    input_cost = (usage["input"] / 1_000_000) * cost_entry["input"]
    output_cost = (usage["output"] / 1_000_000) * cost_entry["output"]
    return round(input_cost + output_cost, 8)


# ---------------------------------------------------------------------------
# LLM Adapters
# ---------------------------------------------------------------------------


def _call_gemini(
    system: str,
    user: str,
    model: str,
    timeout: int,
    api_key: str,
) -> tuple[str, dict[str, int]]:
    """Call Google Gemini API.

    Args:
        system: System prompt.
        user: User prompt.
        model: Model name (e.g. 'gemini-1.5-flash-002').
        timeout: Request timeout in seconds.
        api_key: Gemini API key.

    Returns:
        Tuple of (response_text, usage_dict) where usage_dict has
        'input' and 'output' token counts.
    """
    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}"
        f":generateContent?key={api_key}"
    )
    payload = {
        "system_instruction": {"parts": [{"text": system}]},
        "contents": [{"parts": [{"text": user}]}],
        "generationConfig": {
            "temperature": 0.2,
            "maxOutputTokens": 2048,
            "responseMimeType": "application/json",
        },
    }

    with httpx.Client(timeout=timeout) as client:
        response = client.post(url, json=payload)
        response.raise_for_status()

    data = response.json()
    text = data["candidates"][0]["content"]["parts"][0]["text"]
    usage_metadata = data.get("usageMetadata", {})
    usage = {
        "input": usage_metadata.get("promptTokenCount", 0),
        "output": usage_metadata.get("candidatesTokenCount", 0),
    }
    return text, usage


def _call_claude(
    system: str,
    user: str,
    model: str,
    timeout: int,
    api_key: str,
) -> tuple[str, dict[str, int]]:
    """Call Anthropic Claude API.

    Args:
        system: System prompt.
        user: User prompt.
        model: Model name (e.g. 'claude-3-haiku-20240307').
        timeout: Request timeout in seconds.
        api_key: Anthropic API key.

    Returns:
        Tuple of (response_text, usage_dict).
    """
    url = "https://api.anthropic.com/v1/messages"
    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    payload = {
        "model": model,
        "max_tokens": 2048,
        "system": system,
        "messages": [{"role": "user", "content": user}],
        "temperature": 0.2,
    }

    with httpx.Client(timeout=timeout) as client:
        response = client.post(url, json=payload, headers=headers)
        response.raise_for_status()

    data = response.json()
    text = data["content"][0]["text"]
    usage_data = data.get("usage", {})
    usage = {
        "input": usage_data.get("input_tokens", 0),
        "output": usage_data.get("output_tokens", 0),
    }
    return text, usage


def _call_openai(
    system: str,
    user: str,
    model: str,
    timeout: int,
    api_key: str,
) -> tuple[str, dict[str, int]]:
    """Call OpenAI API.

    Args:
        system: System prompt.
        user: User prompt.
        model: Model name (e.g. 'gpt-4o-mini').
        timeout: Request timeout in seconds.
        api_key: OpenAI API key.

    Returns:
        Tuple of (response_text, usage_dict).
    """
    url = "https://api.openai.com/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0.2,
        "max_tokens": 2048,
        "response_format": {"type": "json_object"},
    }

    with httpx.Client(timeout=timeout) as client:
        response = client.post(url, json=payload, headers=headers)
        response.raise_for_status()

    data = response.json()
    text = data["choices"][0]["message"]["content"]
    usage_data = data.get("usage", {})
    usage = {
        "input": usage_data.get("prompt_tokens", 0),
        "output": usage_data.get("completion_tokens", 0),
    }
    return text, usage


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

# Known provider names (for validation)
_KNOWN_PROVIDERS = {"gemini", "claude", "openai"}


def _get_adapter(provider: str):
    """Get the adapter function for the given provider name.

    Uses module-level function references so that patching in tests works
    correctly (avoids stale references in a dict).
    """
    if provider == "gemini":
        return _call_gemini
    elif provider == "claude":
        return _call_claude
    elif provider == "openai":
        return _call_openai
    return None


def analyze_with_llm(
    incident: "Incident",
    signals: list["Signal"],
) -> "Diagnosis":
    """Analyze incident with LLM and return structured Diagnosis.

    Dispatches to the appropriate LLM adapter based on settings.llm_provider.
    Performs client-side validation: json.loads → Pydantic Diagnosis.
    Logs structured event=llm_call with token/cost metadata.

    Args:
        incident: Parsed incident object.
        signals: List of collected context signals.

    Returns:
        Validated Diagnosis object.

    Raises:
        ValueError: If settings.llm_provider is not in known adapters.
        json.JSONDecodeError: If LLM response is not valid JSON.
        pydantic.ValidationError: If parsed JSON doesn't match Diagnosis schema.
    """
    from .models import Diagnosis  # local import to avoid circular

    provider = settings.llm_provider
    model = settings.llm_model
    timeout = settings.llm_timeout_seconds
    api_key = settings.llm_api_key

    # Validate provider
    if provider not in _KNOWN_PROVIDERS:
        raise ValueError(f"unknown provider {provider}")

    # Format prompts
    user_prompt = format_user_prompt(incident, signals)

    # Call the appropriate adapter
    adapter = _get_adapter(provider)
    start_time = time.monotonic()
    response_text, usage = adapter(
        system=SYSTEM_PROMPT,
        user=user_prompt,
        model=model,
        timeout=timeout,
        api_key=api_key,
    )
    elapsed = time.monotonic() - start_time

    # Client-side validation step (a): parse JSON
    parsed = json.loads(response_text)

    # Estimate cost
    cost = _estimate_cost(usage, model)

    # Client-side validation step (b): validate with Pydantic
    # Use .get() to let Pydantic raise ValidationError for missing required fields
    # rather than KeyError from dict access.
    diagnosis = Diagnosis(
        hypothesis=parsed.get("hypothesis"),  # type: ignore[arg-type]
        evidence_refs=parsed.get("evidence_refs", []),
        confidence=parsed.get("confidence"),  # type: ignore[arg-type]
        suggested_fix=parsed.get("suggested_fix"),  # type: ignore[arg-type]
        suggested_command=parsed.get("suggested_command"),
        model=model,
        tokens_in=usage["input"],
        tokens_out=usage["output"],
        cost_usd=cost,
        created_at=datetime.now(tz=timezone.utc),
    )

    # Structured log: event=llm_call (Req 4.6, 13.6)
    logger.info(
        "LLM call completed",
        extra={
            "event": "llm_call",
            "provider": provider,
            "model": model,
            "tokens_in": usage["input"],
            "tokens_out": usage["output"],
            "cost_usd": cost,
            "latency_seconds": round(elapsed, 3),
            "status": "success",
        },
    )

    return diagnosis
