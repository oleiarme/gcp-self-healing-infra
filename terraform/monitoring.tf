# ==========================================
# Observability — Phase 2 of docs/slo-roadmap
# ==========================================
#
# Goals:
#   * Measure the canonical SLI (external uptime of /healthz) as code.
#   * Fire burn-rate alerts when the 28d / 99.5% availability error budget
#     is being consumed too quickly. Thresholds follow the Google SRE
#     Workbook "Multi-window, multi-burn-rate alerts" pattern.
#   * Surface startup failures as a first-class alertable signal.
#
# Design note on google_monitoring_slo:
#   A formal google_monitoring_slo resource provides the SLO report card in
#   the Cloud Monitoring UI. The alerting below does NOT depend on that
#   resource — it computes the burn rate directly from the uptime_check
#   metric via MQL, which is the canonical, unambiguous definition. The
#   SLO resource is intentionally left for a later PR (schema variants for
#   boolean-metric SLIs need per-team review) and does not block alerting.
#
# Alert burn-rate math (target 99.5% over 28d, bad budget = 0.5%):
#   * Fast burn: good-fraction < 0.928 over 1h   → 14.4× burn rate
#                (consumes 2% of 28d budget per hour)
#   * Slow burn: good-fraction < 0.97  over 6h   → 6×   burn rate
#                (consumes 5% of 28d budget per 6h)

# ------------------------------------------------------------
# Notification channels
# ------------------------------------------------------------

resource "google_monitoring_notification_channel" "email" {
  display_name = "n8n on-call email"
  type         = "email"
  labels = {
    email_address = var.oncall_email
  }
  force_delete = false
}

# Slack delivery (Phase 4 follow-up). Native type = "slack" takes an
# OAuth bot token in sensitive_labels.auth_token — stored server-side by
# Cloud Monitoring and never round-trips through Terraform state in
# plaintext. The channel is only provisioned when var.slack_auth_token
# is non-empty; email stays the single source of paging when it is not
# set. We avoid the `webhook_tokenauth` route for the reason the old
# comment called out: a Slack incoming-webhook URL embeds its own auth
# credential in the path and would leak through state + the Cloud
# Monitoring API.
resource "google_monitoring_notification_channel" "slack" {
  count        = var.slack_auth_token != "" ? 1 : 0
  display_name = "n8n on-call Slack"
  type         = "slack"
  labels = {
    channel_name = var.slack_channel
  }
  sensitive_labels {
    auth_token = var.slack_auth_token
  }
  force_delete = false
}

locals {
  all_notification_channels = concat(
    [google_monitoring_notification_channel.email.id],
    google_monitoring_notification_channel.slack[*].id,
  )
}

# ------------------------------------------------------------
# External SLI probe (the canonical SLI source)
# ------------------------------------------------------------

resource "google_monitoring_uptime_check_config" "n8n" {
  display_name = "n8n /healthz (public)"
  timeout      = "10s"
  period       = "60s"
  # Probed from every available region. A window is counted as a failure
  # only when all six probe locations fail (see burn-rate MQL below).
  selected_regions = []

  http_check {
    path           = "/healthz"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"
    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.n8n_public_host
    }
  }

  content_matchers {
    content = "ok"
    matcher = "CONTAINS_STRING"
  }
}

# ------------------------------------------------------------
# Burn-rate alerts (Google SRE Workbook pattern)
# ------------------------------------------------------------

# GCP user_label values must match [a-z0-9_-]{0,63}, so the canonical
# Runbook link goes in documentation.content (proper markdown) and
# user_labels carry only a label-safe slug for filtering.
locals {
  runbook_url_md = "[Runbook](${var.github_repository_url}/blob/main/Runbook.md)"
}

resource "google_monitoring_alert_policy" "slo_fast_burn" {
  display_name = "n8n SLO fast burn — 14.4× (2% of 28d budget / 1h)"
  severity     = "CRITICAL"
  combiner     = "OR"
  user_labels = {
    runbook = "gcp-self-healing-infra-runbook-md"
    slo     = "availability-99-5-28d"
    window  = "1h"
  }

  conditions {
    display_name = "good-fraction < 0.928 over sliding 1h"
    condition_monitoring_query_language {
      duration = "0s"
      # Sliding 1h window: align fraction_true(1h) produces one point per
      # alignment period (default 1m) whose value is the fraction of `true`
      # samples over the preceding 1h. Detection lag ≤ 1m, matching the
      # SRE Workbook multi-window/multi-burn-rate expectation. A previous
      # revision used `group_by 1h` which builds tumbling wall-clock
      # windows and can delay detection by up to ~59m.
      query = <<-MQL
        fetch uptime_url
        | metric 'monitoring.googleapis.com/uptime_check/check_passed'
        | filter
            (resource.host == '${var.n8n_public_host}')
            && metric.check_id == '${google_monitoring_uptime_check_config.n8n.uptime_check_id}'
        | group_by sliding(1h), [fraction: fraction_true(val())]
        | condition fraction < 0.928
      MQL
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.all_notification_channels
  alert_strategy {
    auto_close = "1800s"
  }
  documentation {
    content   = "n8n is burning its 28d availability error budget at >=14.4× normal rate. Consult ${local.runbook_url_md} §1 / §2 immediately."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "slo_slow_burn" {
  display_name = "n8n SLO slow burn — 6× (5% of 28d budget / 6h)"
  severity     = "WARNING"
  combiner     = "OR"
  user_labels = {
    runbook = "gcp-self-healing-infra-runbook-md"
    slo     = "availability-99-5-28d"
    window  = "6h"
  }

  conditions {
    display_name = "good-fraction < 0.97 over sliding 6h"
    condition_monitoring_query_language {
      duration = "0s"
      # Sliding 6h window: see comment on slo_fast_burn. Detection lag ≤ 1m
      # instead of up to ~5h59m for a tumbling `group_by 6h`.
      query = <<-MQL
        fetch uptime_url
        | metric 'monitoring.googleapis.com/uptime_check/check_passed'
        | filter
            (resource.host == '${var.n8n_public_host}')
            && metric.check_id == '${google_monitoring_uptime_check_config.n8n.uptime_check_id}'
        | group_by sliding(6h), [fraction: fraction_true(val())]
        | condition fraction < 0.97
      MQL
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.all_notification_channels
  alert_strategy {
    auto_close = "7200s"
  }
  documentation {
    content   = "n8n has been burning its 28d availability error budget at 6× normal rate for 6h. Investigate within next business day — ${local.runbook_url_md} §1 / §2."
    mime_type = "text/markdown"
  }
}

# ------------------------------------------------------------
# Log-based metric — startup script CRITICAL lines
# ------------------------------------------------------------

resource "google_logging_metric" "n8n_startup_critical" {
  name    = "n8n/startup_critical"
  project = var.project_id
  filter = join(" AND ", [
    "resource.type=\"gce_instance\"",
    "logName=\"projects/${var.project_id}/logs/startup_log\"",
    # Stable substring; the per-component detail ("n8n" / "cloudflared"
    # / "both") is appended after an em-dash in startup.sh so this
    # filter keeps matching regardless of which component triggered
    # the critical path.
    "textPayload:\"CRITICAL: startup failed\"",
  ])
  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "n8n startup CRITICAL events"
  }
}

resource "google_monitoring_alert_policy" "startup_critical" {
  display_name = "n8n startup script CRITICAL"
  severity     = "WARNING"
  combiner     = "OR"
  user_labels = {
    runbook = "gcp-self-healing-infra-runbook-md"
    scope   = "startup"
  }

  conditions {
    display_name = "startup CRITICAL > 0 in 5 min"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.n8n_startup_critical.name}\" resource.type=\"gce_instance\""
      threshold_value = 0
      comparison      = "COMPARISON_GT"
      duration        = "0s"
      trigger {
        count = 1
      }
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.all_notification_channels
  alert_strategy {
    auto_close = "3600s"
  }
  documentation {
    content   = "scripts/startup.sh hit the terminal 'CRITICAL: startup failed' branch (either n8n, cloudflared, or both did not become healthy in 10 min; the log message names the component). ${local.runbook_url_md} §2 covers boot-loop triage."
    mime_type = "text/markdown"
  }
}

# ------------------------------------------------------------
# Log-ingestion liveness (Phase 4 follow-up)
# ------------------------------------------------------------
# A log-based metric only emits a datapoint when matching log lines are
# ingested. The startup_critical alert above therefore has a silent-
# failure mode: if the Ops Agent is broken (startup.sh install is
# non-fatal with `|| echo WARNING`), the VM can go completely offline
# and we will never see a CRITICAL datapoint — instead of firing an
# alert, the metric just goes quiet. This alert watches for the healthy
# signal going missing, not for the CRITICAL signal appearing.
#
# The condition trips when the `startup_log` logName source has produced
# zero entries for 24 hours, which is long enough that a legitimate
# cold-start window (≤17m) never trips it but a missing Ops Agent does.
# Lookback and threshold are deliberately generous — this is a last-
# resort "observability is dead" signal, not a per-incident pager.
resource "google_monitoring_alert_policy" "log_ingestion_absent" {
  display_name = "n8n log ingestion absent — observability silently dead?"
  severity     = "CRITICAL"
  combiner     = "OR"
  user_labels = {
    runbook = "gcp-self-healing-infra-runbook-md"
    scope   = "observability"
  }

  conditions {
    display_name = "no startup_log entries ingested for 24h"
    condition_absent {
      filter   = "metric.type=\"logging.googleapis.com/log_entry_count\" resource.type=\"gce_instance\" metric.label.\"log\"=\"startup_log\""
      duration = "84600s" # 24h
      trigger {
        count = 1
      }
      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.all_notification_channels
  alert_strategy {
    auto_close = "86400s"
  }
  documentation {
    content   = "Ops Agent is likely broken on the n8n VM — no startup_log entries have been ingested for 24h. Without log ingestion the startup_critical alert above cannot fire, which is a silent observability gap. ${local.runbook_url_md} §2 covers Ops Agent diagnosis (journalctl -u google-cloud-ops-agent)."
    mime_type = "text/markdown"
  }
}
