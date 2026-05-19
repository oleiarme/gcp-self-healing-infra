# ==========================================
# SRE Agent Auto-Diagnostics Infrastructure
# ==========================================
#
# Cloud Function Gen2 (Python 3.12) subscribed to Pub/Sub topic
# `sre-incidents`. Receives Cloud Monitoring alerts, gathers context
# (logs + metrics + external probe), calls LLM (or rule-based fallback),
# and sends structured diagnosis to Telegram.
#
# Tasks: 11.1–11.7
# Requirements: 1.1–1.9, 4.5, 5.6, 6.1–6.3, 7.1, 7.4, 7.5, 7.7, 7.8,
#               8.1–8.3, 8.7

# ==========================================
# APIs required for Cloud Functions Gen2
# ==========================================

resource "google_project_service" "run" {
  project            = var.project_id
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "eventarc" {
  project            = var.project_id
  service            = "eventarc.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudfunctions_v2" {
  project            = var.project_id
  service            = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry_api" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# ==========================================
# 11.1 Pub/Sub Topics
# Requirements: 1.9
# ==========================================

resource "google_pubsub_topic" "sre_incidents" {
  name                       = "sre-incidents"
  project                    = var.project_id
  message_retention_duration = "86400s" # 1 day retention
}

resource "google_pubsub_topic" "sre_incidents_dlq" {
  name    = "sre-incidents-dlq"
  project = var.project_id
}

# Notification channel for alert policies → SRE agent via Pub/Sub
resource "google_monitoring_notification_channel" "sre_agent_pubsub" {
  display_name = "SRE-agent Pub/Sub"
  type         = "pubsub"
  labels = {
    topic = google_pubsub_topic.sre_incidents.id
  }
  force_delete = false
}

# Cloud Monitoring service account needs pubsub.publisher on the topic
resource "google_pubsub_topic_iam_member" "sre_monitoring_publisher" {
  topic   = google_pubsub_topic.sre_incidents.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.sre_current.number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
  project = var.project_id
}

data "google_project" "sre_current" {
  project_id = var.project_id
}

# ==========================================
# 11.2 Service Account and IAM Bindings
# Requirements: 6.1, 6.2, 6.3
# ==========================================
#
# SECURITY NOTE: This service account has READ-ONLY access only.
# NO write roles are granted — the agent observes but never mutates
# infrastructure. This is an explicit design constraint (Req 6.2).

resource "google_service_account" "sre_agent" {
  account_id   = "sre-agent"
  display_name = "SRE diagnostic agent"
  description  = "Read-only SA for the SRE auto-diagnostics Cloud Function. NO write roles allowed."
}

# roles/logging.viewer — read Cloud Logging entries for context gathering
resource "google_project_iam_member" "sre_agent_logging_viewer" {
  project = var.project_id
  role    = "roles/logging.viewer"
  member  = "serviceAccount:${google_service_account.sre_agent.email}"
}

# roles/monitoring.viewer — read Cloud Monitoring metrics and alert state
resource "google_project_iam_member" "sre_agent_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.sre_agent.email}"
}

# roles/datastore.user — Firestore read/write for dedup, correlation, budget tracking
resource "google_project_iam_member" "sre_agent_datastore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.sre_agent.email}"
}

# roles/compute.viewer — read instance metadata (creationTimestamp for bootstrap grace)
resource "google_project_iam_member" "sre_agent_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.sre_agent.email}"
}

# GCS bucket for Cloudflare logpush storage (Phase 4)
resource "google_storage_bucket" "cloudflare_logs" {
  name                        = "${var.project_id}-cloudflare-logs"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

# roles/storage.objectViewer — read Cloudflare logs bucket (Phase 4)
resource "google_storage_bucket_iam_member" "sre_agent_cloudflare_logs_reader" {
  bucket = google_storage_bucket.cloudflare_logs.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.sre_agent.email}"
}

# Per-secret access: roles/secretmanager.secretAccessor
# Only on specific secrets — never project-wide (Req 6.3)
resource "google_secret_manager_secret" "sre_llm_key" {
  secret_id = "sre-agent-llm-key"
  replication {
    user_managed {
      replicas { location = "us-central1" }
    }
  }
}

resource "google_secret_manager_secret_version" "sre_llm_key_v" {
  secret      = google_secret_manager_secret.sre_llm_key.id
  secret_data = var.sre_agent_llm_api_key != "" ? var.sre_agent_llm_api_key : "placeholder"
}

resource "google_secret_manager_secret_iam_member" "sre_agent_llm_key_access" {
  secret_id = google_secret_manager_secret.sre_llm_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.sre_agent.email}"
}

# Reuse existing telegram-bot-token secret (from telegram.tf)
resource "google_secret_manager_secret_iam_member" "sre_agent_tg_token_access" {
  count     = local.telegram_enabled ? 1 : 0
  secret_id = google_secret_manager_secret.telegram_bot_token[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.sre_agent.email}"
}

# ==========================================
# 11.3 Cloud Function Gen2 `sre-agent`
# Requirements: 4.5, 5.6, 7.1, 7.5
# ==========================================

# Source code archive
data "archive_file" "sre_agent_zip" {
  type        = "zip"
  source_dir  = "${path.module}/functions/sre_agent"
  output_path = "${path.module}/.build/sre_agent.zip"
  excludes    = ["__pycache__", "*.pyc", ".pytest_cache", "tests"]
}

# Source bucket for Cloud Function deployment
resource "google_storage_bucket" "sre_agent_src" {
  name                        = "${var.project_id}-sre-agent-src"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition { age = 30 }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket_object" "sre_agent_zip" {
  name   = "sre_agent_${data.archive_file.sre_agent_zip.output_md5}.zip"
  bucket = google_storage_bucket.sre_agent_src.name
  source = data.archive_file.sre_agent_zip.output_path
}

resource "google_cloudfunctions2_function" "sre_agent" {
  name     = "sre-agent"
  location = var.region
  project  = var.project_id

  build_config {
    runtime     = "python312"
    entry_point = "sre_agent"
    source {
      storage_source {
        bucket = google_storage_bucket.sre_agent_src.name
        object = google_storage_bucket_object.sre_agent_zip.name
      }
    }
  }

  service_config {
    available_memory      = "512Mi"
    available_cpu         = "0.5"
    timeout_seconds       = 300
    min_instance_count    = 0
    max_instance_count    = 5
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    service_account_email = google_service_account.sre_agent.email

    environment_variables = {
      # Identity / GCP
      GCP_PROJECT_ID  = var.project_id
      DEFAULT_ZONE    = var.zone
      N8N_PUBLIC_HOST = var.n8n_public_host

      # Kill-switch
      SRE_AGENT_ENABLED = "true"

      # LLM configuration
      LLM_PROVIDER           = "gemini"
      LLM_MODEL              = "gemini-1.5-flash-002"
      LLM_BUDGET_USD_PER_DAY = "2.00"
      LLM_TIMEOUT_SECONDS    = "45"

      # Telegram
      TG_CHAT_ID = var.telegram_chat_id

      # Context-gathering
      LOG_LOOKBACK_MINUTES    = "5"
      LOG_LINES_PER_CONTAINER = "100"
      MAX_CONTEXT_TOKENS      = "12000"

      # Processing
      PROCESSING_TIMEOUT_SECONDS = "240"

      # OS profile
      HOST_OS = "cos"

      # Time-window contract (must match MIG initial_delay_sec)
      BOOTSTRAP_GRACE_SECONDS           = "1800"
      LIVE_MIGRATION_WINDOW_SEC         = "300"
      CORRELATION_WINDOW_SEC            = "90"
      CROSS_KIND_CORRELATION_WINDOW_SEC = "180"

      # Dedup & correlation store
      DEDUP_TTL_SECONDS       = "3600"
      WINDOW_MAX_OPEN_SECONDS = "1800"
      INSTANCE_CACHE_TTL_SEC  = "60"
    }

    secret_environment_variables {
      key        = "LLM_API_KEY"
      project_id = var.project_id
      secret     = google_secret_manager_secret.sre_llm_key.secret_id
      version    = "latest"
    }

    dynamic "secret_environment_variables" {
      for_each = local.telegram_enabled ? [1] : []
      content {
        key        = "TG_BOT_TOKEN"
        project_id = var.project_id
        secret     = google_secret_manager_secret.telegram_bot_token[0].secret_id
        version    = "latest"
      }
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.sre_incidents.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }

  depends_on = [
    google_project_service.run,
    google_project_service.eventarc,
    google_project_service.cloudfunctions_v2,
    google_project_service.artifactregistry_api,
    google_secret_manager_secret_version.sre_llm_key_v,
  ]
}

# ==========================================
# 11.4 Log-based Metrics (COS)
# Requirements: 8.1, 8.2, 8.3
# ==========================================
#
# Strategy: Standardized on COS metrics. Alert policies reference the
# logical names and remain OS-invariant.

# --- postgres_fatal ---

resource "google_logging_metric" "postgres_fatal" {
  name    = "n8n/postgres_fatal"
  project = var.project_id
  filter  = <<-EOT
    resource.type="gce_instance"
    AND jsonPayload.container.name="postgres"
    AND (
      jsonPayload.log=~"(FATAL|PANIC|deadlock detected|out of memory)"
      OR textPayload=~"(FATAL|PANIC|deadlock detected|out of memory)"
    )
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# --- n8n_error ---

resource "google_logging_metric" "n8n_error" {
  name    = "n8n/n8n_error"
  project = var.project_id
  filter  = <<-EOT
    resource.type="gce_instance"
    AND jsonPayload.container.name="n8n"
    AND (
      jsonPayload.log=~"(ECONNREFUSED|workflow execution failed|ETIMEDOUT|FATAL|level=\"error\"|\"level\":\"error\")"
      OR textPayload=~"(ECONNREFUSED|workflow execution failed|ETIMEDOUT|FATAL)"
    )
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# --- oom_killed ---

resource "google_logging_metric" "oom_killed" {
  name    = "n8n/oom_killed"
  project = var.project_id
  filter  = <<-EOT
    resource.type="gce_instance"
    AND (
      textPayload=~"Out of memory: Killed process"
      OR jsonPayload.MESSAGE=~"Out of memory: Killed process"
    )
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

# ==========================================
# 11.5 Alert Policies
# Requirements: 1.1–1.5
# ==========================================
#
# All alert policies route to the SRE agent Pub/Sub notification channel.
# They use the stable logical metric names (n8n/postgres_fatal, etc.)
# which are OS-invariant.

resource "google_monitoring_alert_policy" "sre_vm_cpu_high" {
  display_name = "VM CPU > 85% for 3m"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "CPU utilization sustained > 85%"
    condition_threshold {
      filter          = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "180s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.sre_agent_pubsub.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "VM CPU utilization exceeded 85% for 3 minutes. SRE agent will gather context and diagnose."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "sre_vm_memory_high" {
  display_name = "VM OOM kill detected"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "OOM kill event (log-based metric > 0)"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/n8n/oom_killed\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.sre_agent_pubsub.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "OOM killer invoked on the VM. SRE agent will diagnose memory pressure root cause."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "sre_postgres_fatal" {
  display_name = "Postgres FATAL/PANIC"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "postgres_fatal rate > 0 for 60s"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/n8n/postgres_fatal\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.sre_agent_pubsub.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "Postgres emitted FATAL or PANIC level log. SRE agent will diagnose database issue."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "sre_n8n_error_spike" {
  display_name = "n8n ERROR spike (>5/min)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "n8n_error rate > 5/min for 60s"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/n8n/n8n_error\" resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "60s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.sre_agent_pubsub.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "n8n error rate exceeded 5 per minute. SRE agent will diagnose application errors."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "sre_external_unreachable" {
  display_name = "n8n unreachable from internet (deep healthcheck)"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "uptime check /healthz/deep failing (<50% probes OK for 3m)"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" resource.type=\"uptime_url\" metric.labels.check_id=\"${google_monitoring_uptime_check_config.n8n_deep.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 0.5
      duration        = "180s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_FRACTION_TRUE"
        cross_series_reducer = "REDUCE_MEAN"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.sre_agent_pubsub.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "n8n /healthz/deep is failing from multiple probe regions. SRE agent will run external reachability probe and diagnose."
    mime_type = "text/markdown"
  }
}

# ==========================================
# 11.6 Uptime Check /healthz/deep
# Requirements: 8.7
# ==========================================

resource "google_monitoring_uptime_check_config" "n8n_deep" {
  display_name = "n8n /healthz/deep"
  timeout      = "10s"
  period       = "60s"

  # 4 regions for geographic diversity
  selected_regions = ["USA", "EUROPE", "SOUTH_AMERICA", "ASIA_PACIFIC"]

  http_check {
    path           = "/healthz/deep"
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
}

# ==========================================
# 11.7 Meta-metrics (log-based) for Agent Observability
# Requirements: 7.4, 7.7, 7.8
# ==========================================
#
# These metrics are emitted by the Cloud Function via structured logging
# (event=<type> key=value pairs). Cloud Logging log-based metrics extract
# counters from these structured log entries.

resource "google_logging_metric" "sre_agent_invocations" {
  name    = "sre_agent/invocations_total"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    AND jsonPayload.event="invocation"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "sre_agent_llm_latency" {
  name    = "sre_agent/llm_latency_seconds"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    AND jsonPayload.event="llm_call"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "s"
  }
  value_extractor = "EXTRACT(jsonPayload.latency_seconds)"
  bucket_options {
    explicit_buckets {
      bounds = [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 45.0, 60.0]
    }
  }
}

resource "google_logging_metric" "sre_agent_llm_tokens" {
  name    = "sre_agent/llm_tokens_total"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    AND jsonPayload.event="llm_call"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "1"
  }
  value_extractor = "EXTRACT(jsonPayload.tokens_total)"
  bucket_options {
    explicit_buckets {
      bounds = [100, 500, 1000, 2000, 5000, 10000, 20000, 50000]
    }
  }
}

resource "google_logging_metric" "sre_agent_llm_cost" {
  name    = "sre_agent/llm_cost_usd_total"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    AND jsonPayload.event="llm_call"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "1"
  }
  value_extractor = "EXTRACT(jsonPayload.cost_usd)"
  bucket_options {
    explicit_buckets {
      bounds = [0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5]
    }
  }
}

resource "google_logging_metric" "sre_agent_diagnosis_failed" {
  name    = "sre_agent/diagnosis_failed_total"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    AND jsonPayload.event="diagnosis_failed"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "sre_agent_suppressed" {
  name    = "sre_agent/suppressed_total"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    AND jsonPayload.event="suppressed"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "reason"
      value_type  = "STRING"
      description = "Suppression reason (live_migration, bootstrap_grace)"
    }
  }
  label_extractors = {
    "reason" = "EXTRACT(jsonPayload.reason)"
  }
}

resource "google_logging_metric" "sre_agent_correlated" {
  name    = "sre_agent/correlated_total"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    AND jsonPayload.event="correlated"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "sre_agent_compute_api_calls" {
  name    = "sre_agent/compute_api_calls_total"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    AND jsonPayload.event="compute_api_call"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "cache_hit"
      value_type  = "STRING"
      description = "Whether the Compute API call was served from cache (true/false)"
    }
  }
  label_extractors = {
    "cache_hit" = "EXTRACT(jsonPayload.cache_hit)"
  }
}

# Meta-alert: SRE agent health degraded (diagnosis_failed > 5 in 60 min)
resource "google_monitoring_alert_policy" "sre_agent_health_degraded" {
  display_name = "SRE agent health degraded (diagnosis failures)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "diagnosis_failed > 5 in 60 min rolling window"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/sre_agent/diagnosis_failed_total\" resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "0s"
      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  # Route to both SRE agent channel and human notification channels
  notification_channels = concat(
    [google_monitoring_notification_channel.sre_agent_pubsub.id],
    local.all_notification_channels,
  )

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    content   = "SRE agent has failed to produce a diagnosis more than 5 times in the last hour. Check LLM provider availability, API key validity, and Cloud Function logs."
    mime_type = "text/markdown"
  }
}
