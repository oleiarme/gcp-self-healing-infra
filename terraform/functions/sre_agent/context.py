"""Сбор контекста для диагностики инцидента.

Функции:
  - get_logs(project_id, container, started_at, lookback_minutes, max_lines)
    → (list[LogLine], bool)
  - get_metric_series(project_id, instance_id, started_at, lookback_minutes)
    → list[Metric]
  - gather_context(incident, settings) → (list[Signal], dict)
  - get_cloudflared_logs(project_id, started_at, lookback_minutes, max_lines)
    → (list[LogLine], bool)
  - probe_external_reachability(host) — DNS → TCP → HTTPS → /healthz/deep
  - is_live_migration_in_window(incident) — проверка Live Migration ±300s
  - instance_age_seconds_cached(instance) — возраст VM с TTL-кэшем

Requirements: 2.1–2.5, 2.9, 11.2, 11.3
"""

import logging
import socket
from datetime import datetime, timedelta, timezone

import dns.resolver
import httpx
from google.api_core import exceptions as gcp_exceptions
from google.cloud import logging_v2, monitoring_v3

from .models import Incident, LogLine, Metric, Signal

logger = logging.getLogger(__name__)

# Module-level clients — lazy-initialized to allow mocking in tests
_logging: logging_v2.Client | None = None
_metrics: monitoring_v3.MetricServiceClient | None = None


def _get_logging_client(project_id: str) -> logging_v2.Client:
    """Get or create Cloud Logging client."""
    global _logging
    if _logging is None:
        _logging = logging_v2.Client(project=project_id)
    return _logging


def _get_metrics_client() -> monitoring_v3.MetricServiceClient:
    """Get or create Cloud Monitoring client."""
    global _metrics
    if _metrics is None:
        _metrics = monitoring_v3.MetricServiceClient()
    return _metrics


def get_logs(
    project_id: str,
    container_name: str,
    started_at: datetime,
    lookback_minutes: int,
    max_lines: int,
) -> tuple[list[LogLine], bool]:
    """Fetch container logs from Cloud Logging with heterogeneous filter.

    Uses a disjunction filter that matches both:
    - Ubuntu (Ops Agent): labels."container_name"
    - COS (built-in fluent-bit): jsonPayload.container.name

    Args:
        project_id: GCP project ID.
        container_name: Container name to filter (e.g. "n8n", "postgres").
        started_at: Incident start time.
        lookback_minutes: How many minutes before started_at to look back.
        max_lines: Maximum number of log lines to return (LOG_LINES_PER_CONTAINER).

    Returns:
        Tuple of (log_lines, partial) where partial=True if API error occurred.
    """
    since = started_at - timedelta(minutes=lookback_minutes)
    iso = since.isoformat()

    # Гетерогенный фильтр: матчит и Ubuntu (Ops Agent → labels."container_name"),
    # и COS (built-in fluent-bit → jsonPayload.container.name).
    filter_str = (
        f'resource.type="gce_instance" '
        f"AND ("
        f'labels."container_name"="{container_name}" '
        f'OR jsonPayload.container.name="{container_name}"'
        f") "
        f'AND timestamp>="{iso}"'
    )

    try:
        client = _get_logging_client(project_id)
        entries = client.list_entries(
            filter_=filter_str,
            page_size=max_lines,
            order_by="timestamp desc",
        )

        out: list[LogLine] = []
        for entry in entries:
            if len(out) >= max_lines:
                break
            out.append(
                LogLine(
                    timestamp=entry.timestamp,
                    text=str(entry.payload)[:2000],
                    container=container_name,
                )
            )
        return out, False

    except (
        gcp_exceptions.ResourceExhausted,
        gcp_exceptions.InternalServerError,
        gcp_exceptions.ServiceUnavailable,
        gcp_exceptions.DeadlineExceeded,
        gcp_exceptions.GoogleAPICallError,
    ) as exc:
        logger.warning(
            "Cloud Logging API error for container=%s: %s",
            container_name,
            str(exc),
            extra={"event": "logging_api_error", "container": container_name},
        )
        return [], True


def get_metric_series(
    project_id: str,
    instance_id: str,
    started_at: datetime,
    lookback_minutes: int,
) -> list[Metric]:
    """Query CPU utilization metric from Cloud Monitoring.

    Args:
        project_id: GCP project ID.
        instance_id: GCE instance ID for filtering.
        started_at: Incident start time.
        lookback_minutes: How many minutes before started_at to look back.

    Returns:
        List of Metric points for CPU utilization.
    """
    metric_type = "compute.googleapis.com/instance/cpu/utilization"
    since = started_at - timedelta(minutes=lookback_minutes)
    project_name = f"projects/{project_id}"

    interval = monitoring_v3.TimeInterval(
        start_time=since,
        end_time=started_at,
    )

    request = monitoring_v3.ListTimeSeriesRequest(
        name=project_name,
        filter=f'metric.type="{metric_type}" AND resource.labels.instance_id="{instance_id}"',
        interval=interval,
        view=monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
    )

    client = _get_metrics_client()
    out: list[Metric] = []

    try:
        for ts in client.list_time_series(request=request):
            for point in ts.points:
                value = point.value.double_value or float(point.value.int64_value or 0)
                out.append(
                    Metric(
                        timestamp=point.interval.end_time,
                        value=value,
                        metric_type=metric_type,
                    )
                )
    except (
        gcp_exceptions.GoogleAPICallError,
        gcp_exceptions.DeadlineExceeded,
    ) as exc:
        logger.warning(
            "Cloud Monitoring API error: %s",
            str(exc),
            extra={"event": "monitoring_api_error"},
        )

    return out


def get_cloudflared_logs(
    project_id: str,
    started_at: datetime,
    lookback_minutes: int,
    max_lines: int,
) -> tuple[list[LogLine], bool]:
    """Fetch cloudflared container logs. Same pattern as get_logs.

    Args:
        project_id: GCP project ID.
        started_at: Incident start time.
        lookback_minutes: How many minutes before started_at to look back.
        max_lines: Maximum number of log lines to return.

    Returns:
        Tuple of (log_lines, partial) where partial=True if API error occurred.
    """
    return get_logs(project_id, "cloudflared", started_at, lookback_minutes, max_lines)


def gather_context(
    incident: Incident,
    settings,
) -> tuple[list[Signal], dict]:
    """Orchestrate context collection for an incident.

    Collects:
    - n8n container logs
    - postgres container logs
    - CPU utilization metrics
    - For external_unreachable: also probe + cloudflared logs

    Args:
        incident: The normalized incident to gather context for.
        settings: Settings object with project_id, log_lookback_minutes, etc.

    Returns:
        Tuple of (signals, metadata) where metadata has partial/partial_reason.
    """
    project_id = settings.project_id
    lookback = settings.log_lookback_minutes
    max_lines = settings.log_lines_per_container

    partial = False
    partial_reasons: list[str] = []

    # Collect n8n logs
    n8n_logs, n8n_partial = get_logs(
        project_id, "n8n", incident.started_at, lookback, max_lines
    )
    if n8n_partial:
        partial = True
        partial_reasons.append("n8n logs: API error")

    # Collect postgres logs
    pg_logs, pg_partial = get_logs(
        project_id, "postgres", incident.started_at, lookback, max_lines
    )
    if pg_partial:
        partial = True
        partial_reasons.append("postgres logs: API error")

    # Collect CPU metrics
    instance_id = incident.resource.get("instance_id", "")
    cpu_metrics = get_metric_series(
        project_id, instance_id, incident.started_at, lookback
    )

    signals: list[Signal] = [
        Signal(
            kind="n8n_logs",
            source="n8n_logs",
            data=[line.model_dump(mode="json") for line in n8n_logs],
        ),
        Signal(
            kind="pg_logs",
            source="pg_logs",
            data=[line.model_dump(mode="json") for line in pg_logs],
        ),
        Signal(
            kind="cpu_metric",
            source="cpu_metric",
            data=[m.model_dump(mode="json") for m in cpu_metrics],
        ),
    ]

    # For external_unreachable: also call probe and get cloudflared logs
    if incident.kind == "external_unreachable":
        host = incident.resource.get("public_host") or settings.n8n_public_host
        probe_result = probe_external_reachability(host)
        signals.append(
            Signal(
                kind="external_probe",
                source="external_probe",
                data=probe_result,
            )
        )

        cf_logs, cf_partial = get_cloudflared_logs(
            project_id, incident.started_at, lookback, max_lines
        )
        if cf_partial:
            partial = True
            partial_reasons.append("cloudflared logs: API error")

        signals.append(
            Signal(
                kind="cloudflared_logs",
                source="cloudflared_logs",
                data=[line.model_dump(mode="json") for line in cf_logs],
            )
        )

    metadata = {
        "partial": partial,
        "partial_reason": "; ".join(partial_reasons) if partial_reasons else None,
    }

    return signals, metadata


def probe_external_reachability(host: str) -> dict:
    """Probe external reachability: DNS → TCP:443 → HTTPS root → /healthz/deep.

    Four phases run strictly sequentially. Each phase is independent —
    failure of one does not block subsequent phases.
    Individual timeouts: DNS 5s, TCP 5s, HTTPS root 10s, HTTPS /healthz/deep 10s.
    Total wall-clock ≤ 30 seconds.
    Always returns a dict, never raises.

    Args:
        host: The hostname to probe.

    Returns:
        Dict with results of each probe phase:
        - dns_ok, dns_ips, dns_error
        - tcp_ok, tcp_error
        - https_root_ok, https_root_status, https_root_error
        - healthz_ok, healthz_status, healthz_error

    Requirements: 2.6, 2.7, 2.8
    """
    result: dict = {
        "dns_ok": False,
        "dns_ips": [],
        "dns_error": None,
        "tcp_ok": False,
        "tcp_error": None,
        "https_root_ok": False,
        "https_root_status": None,
        "https_root_error": None,
        "healthz_ok": False,
        "healthz_status": None,
        "healthz_error": None,
    }

    # Phase 1: DNS resolution (timeout 5s)
    try:
        answers = dns.resolver.resolve(host, "A", lifetime=5)
        ips = [rdata.address for rdata in answers]
        result["dns_ok"] = True
        result["dns_ips"] = ips
    except Exception as exc:
        result["dns_error"] = str(exc)

    # Phase 2: TCP connect to port 443 (timeout 5s)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect((host, 443))
            result["tcp_ok"] = True
    except Exception as exc:
        result["tcp_error"] = str(exc)

    # Phase 3: HTTPS GET root (timeout 10s)
    try:
        resp = httpx.get(f"https://{host}/", timeout=10)
        result["https_root_ok"] = 200 <= resp.status_code < 400
        result["https_root_status"] = resp.status_code
    except Exception as exc:
        result["https_root_error"] = str(exc)

    # Phase 4: HTTPS GET /healthz/deep (timeout 10s)
    try:
        resp = httpx.get(f"https://{host}/healthz/deep", timeout=10)
        result["healthz_status"] = resp.status_code
        result["healthz_ok"] = 200 <= resp.status_code < 400
    except Exception as exc:
        result["healthz_error"] = str(exc)

    return result


# ---------------------------------------------------------------------------
# Live Migration detection (Req 9.2)
# ---------------------------------------------------------------------------


def is_live_migration_in_window(incident: Incident) -> bool:
    """Check if a Live Migration event occurred within ±LIVE_MIGRATION_WINDOW_SEC.

    Queries Cloud Logging for `compute.instances.migrateOnHostMaintenance`
    or `compute.instances.hostError` events in the window around
    incident.started_at.

    On API error, returns False (allow processing to continue).

    Args:
        incident: The incident to check.

    Returns:
        True if live migration detected in window, False otherwise.
    """
    from .settings import settings

    window_sec = settings.live_migration_window_sec
    vm_name = incident.resource.get("vm", "")
    if not vm_name:
        return False

    project_id = settings.project_id
    since = incident.started_at - timedelta(seconds=window_sec)
    until = incident.started_at + timedelta(seconds=window_sec)

    filter_str = (
        f'resource.type="gce_instance" '
        f'AND protoPayload.methodName=('
        f'"compute.instances.migrateOnHostMaintenance" '
        f'OR "compute.instances.hostError"'
        f') '
        f'AND resource.labels.instance_id="{vm_name}" '
        f'AND timestamp>="{since.isoformat()}" '
        f'AND timestamp<="{until.isoformat()}"'
    )

    try:
        client = _get_logging_client(project_id)
        entries = client.list_entries(
            filter_=filter_str,
            page_size=1,
        )
        for _ in entries:
            return True
        return False
    except Exception as exc:
        logger.warning(
            "Live migration check failed: %s",
            str(exc),
            extra={"event": "live_migration_check_error"},
        )
        return False


# ---------------------------------------------------------------------------
# Instance age with TTL cache (Req 9.3, 7.8)
# ---------------------------------------------------------------------------

_instance_age_cache: dict[str, tuple[float, datetime]] = {}


def instance_age_seconds_cached(incident: Incident) -> float | None:
    """Get VM instance age in seconds, with per-instance TTL cache.

    Uses Compute API to fetch creation_timestamp. Caches result for
    INSTANCE_CACHE_TTL_SEC (default 60s) to avoid API throttling.

    On API error, returns None (allow processing to continue).

    Args:
        incident: The incident containing resource.vm.

    Returns:
        Age in seconds, or None if VM name not available or API error.
    """
    from .settings import settings

    vm_name = incident.resource.get("vm", "")
    if not vm_name:
        return None

    now = datetime.now(tz=timezone.utc)
    cache_ttl = settings.instance_cache_ttl_sec

    # Check cache
    if vm_name in _instance_age_cache:
        cached_age, cached_at = _instance_age_cache[vm_name]
        if (now - cached_at).total_seconds() < cache_ttl:
            logger.info(
                "Compute API cache hit",
                extra={"event": "compute_api_call", "cache_hit": True},
            )
            # Recalculate age based on original creation time
            creation_time = cached_at - timedelta(seconds=cached_age)
            return (now - creation_time).total_seconds()

    # Cache miss — call Compute API
    logger.info(
        "Compute API cache miss",
        extra={"event": "compute_api_call", "cache_hit": False},
    )

    try:
        from google.cloud import compute_v1

        client = compute_v1.InstancesClient()
        instance = client.get(
            project=settings.project_id,
            zone=settings.default_zone,
            instance=vm_name,
        )
        creation_ts = instance.creation_timestamp
        if creation_ts:
            # Parse creation timestamp
            creation_dt = datetime.fromisoformat(
                creation_ts.replace("Z", "+00:00")
            )
            age = (now - creation_dt).total_seconds()
            _instance_age_cache[vm_name] = (age, now)
            return age
        return None
    except Exception as exc:
        logger.warning(
            "Instance age lookup failed: %s",
            str(exc),
            extra={"event": "compute_api_error", "vm": vm_name},
        )
        return None


# ---------------------------------------------------------------------------
# Token truncation (Req 11.1–11.3)
# ---------------------------------------------------------------------------


def _estimate_tokens(text: str) -> int:
    """Estimate token count using len(text) // 4 heuristic."""
    return max(1, len(text) // 4)


def truncate_context(
    signals: list[Signal],
    max_tokens: int | None = None,
) -> list[Signal]:
    """Truncate log signals to fit within token budget.

    Strategy:
    - Metrics and probe signals are NEVER truncated.
    - Log signals are truncated oldest-first (freshest preserved).
    - A truncation marker is prepended when lines are removed.

    Args:
        signals: List of Signal objects to potentially truncate.
        max_tokens: Maximum token budget. Uses settings.max_context_tokens if None.

    Returns:
        List of Signal objects fitting within the token budget.
    """
    from .settings import settings as _settings

    if max_tokens is None:
        max_tokens = _settings.max_context_tokens

    if not signals:
        return signals

    # Separate log signals from non-log signals (metrics, probes)
    log_signals: list[tuple[int, Signal]] = []
    non_log_signals: list[tuple[int, Signal]] = []

    for idx, signal in enumerate(signals):
        if isinstance(signal.data, list) and signal.kind.endswith("_logs"):
            log_signals.append((idx, signal))
        else:
            non_log_signals.append((idx, signal))

    # Calculate tokens for non-log signals (these are never truncated)
    non_log_tokens = sum(
        _estimate_tokens(str(s.data)) for _, s in non_log_signals
    )

    # Available budget for logs
    log_budget = max_tokens - non_log_tokens
    if log_budget <= 0:
        # No budget for logs — return non-log signals only, preserving order
        result = [None] * len(signals)
        for idx, s in non_log_signals:
            result[idx] = s
        return [s for s in result if s is not None]

    # Calculate current log tokens
    total_log_tokens = sum(
        _estimate_tokens(str(s.data)) for _, s in log_signals
    )

    if total_log_tokens <= log_budget:
        # Under budget — return as-is
        return signals

    # Need to truncate logs — distribute budget proportionally
    result_signals: dict[int, Signal] = {}
    for idx, s in non_log_signals:
        result_signals[idx] = s

    # Budget per log signal (proportional)
    budget_per_log = log_budget // max(len(log_signals), 1)

    for idx, signal in log_signals:
        data = signal.data
        if not isinstance(data, list):
            result_signals[idx] = signal
            continue

        current_tokens = _estimate_tokens(str(data))
        if current_tokens <= budget_per_log:
            result_signals[idx] = signal
            continue

        # Truncate: remove oldest lines (beginning of list), keep newest (end)
        # Binary search for how many lines fit
        lines = data
        kept_lines: list = []
        running_tokens = 0

        # Work backwards from newest
        for line in reversed(lines):
            line_tokens = _estimate_tokens(str(line))
            if running_tokens + line_tokens > budget_per_log:
                break
            kept_lines.insert(0, line)
            running_tokens += line_tokens

        removed_count = len(lines) - len(kept_lines)
        if removed_count > 0:
            marker = f"[truncated: oldest {removed_count} lines removed]"
            kept_lines.insert(0, marker)

        result_signals[idx] = Signal(
            kind=signal.kind,
            source=signal.source,
            data=kept_lines,
        )

    # Reconstruct in original order
    return [result_signals[i] for i in sorted(result_signals.keys())]
