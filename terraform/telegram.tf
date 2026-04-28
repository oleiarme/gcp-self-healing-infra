# ==========================================
# Telegram alert delivery (Pub/Sub → Cloud Function → Bot API)
# ==========================================
#
# GCP Cloud Monitoring has no native Telegram channel type. The standard
# pattern is: alert → Pub/Sub notification channel → Cloud Function that
# POSTs to https://api.telegram.org/bot<TOKEN>/sendMessage.
#
# All resources below are opt-in: when var.telegram_bot_token is empty
# (default), count = 0 and nothing is provisioned. Setting
# TF_VAR_telegram_bot_token + TF_VAR_telegram_chat_id enables the full
# chain. Messages land in a specific Telegram topic/thread when
# var.telegram_thread_id is also set.
#
# Cost: Cloud Functions free tier covers 2M invocations/month. With ~50
# alerts/month this is effectively $0.

locals {
  telegram_enabled = var.telegram_bot_token != ""
}

# --- APIs required for Cloud Functions Gen1 + Pub/Sub ---

resource "google_project_service" "cloudfunctions" {
  count   = local.telegram_enabled ? 1 : 0
  project = var.project_id
  service = "cloudfunctions.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "cloudbuild" {
  count   = local.telegram_enabled ? 1 : 0
  project = var.project_id
  service = "cloudbuild.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "pubsub" {
  count   = local.telegram_enabled ? 1 : 0
  project = var.project_id
  service = "pubsub.googleapis.com"

  disable_on_destroy = false
}

# --- Pub/Sub topic for Cloud Monitoring alerts ---

# checkov:skip=CKV_GCP_83: Alert payloads contain no sensitive data; CSEK adds key-management overhead with no security benefit
resource "google_pubsub_topic" "alerts" {
  count   = local.telegram_enabled ? 1 : 0
  name    = "n8n-monitoring-alerts"
  project = var.project_id

  depends_on = [google_project_service.pubsub]
}

# Cloud Monitoring notification channel (type = pubsub). This is added
# to local.all_notification_channels in monitoring.tf so every existing
# alert policy automatically fans out to Telegram.
resource "google_monitoring_notification_channel" "telegram" {
  count        = local.telegram_enabled ? 1 : 0
  display_name = "n8n Telegram (via Pub/Sub)"
  type         = "pubsub"
  labels = {
    topic = google_pubsub_topic.alerts[0].id
  }
  force_delete = false
}

# Cloud Monitoring service account needs pubsub.publisher on the topic
# to deliver alert payloads. The SA is auto-created by GCP when Cloud
# Monitoring is first used; its email follows a fixed convention.
resource "google_pubsub_topic_iam_member" "monitoring_publisher" {
  count   = local.telegram_enabled ? 1 : 0
  topic   = google_pubsub_topic.alerts[0].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.current[0].number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
  project = var.project_id
}

data "google_project" "current" {
  count      = local.telegram_enabled ? 1 : 0
  project_id = var.project_id
}

# --- Cloud Function source archive ---

data "archive_file" "telegram_fn" {
  count       = local.telegram_enabled ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/functions/telegram_alert"
  output_path = "${path.module}/functions/telegram_alert.zip"
}

resource "google_storage_bucket" "fn_source" {
  count                       = local.telegram_enabled ? 1 : 0
  name                        = "${var.project_id}-fn-source"
  location                    = "US-CENTRAL1"
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

resource "google_storage_bucket_object" "telegram_fn" {
  count  = local.telegram_enabled ? 1 : 0
  name   = "telegram_alert-${data.archive_file.telegram_fn[0].output_md5}.zip"
  bucket = google_storage_bucket.fn_source[0].name
  source = data.archive_file.telegram_fn[0].output_path
}

# --- Cloud Function Gen1 (lighter than Gen2, no Eventarc/Cloud Run) ---

# checkov:skip=CKV_GCP_124: Function is Pub/Sub-triggered (event_trigger), not HTTP-invoked; ingress_settings is irrelevant
resource "google_cloudfunctions_function" "telegram_alert" {
  count       = local.telegram_enabled ? 1 : 0
  name        = "n8n-telegram-alert"
  description = "Forward Cloud Monitoring alerts to Telegram"
  runtime     = "python312"
  region      = var.region

  available_memory_mb   = 128
  timeout               = 30
  entry_point           = "handle_pubsub"
  source_archive_bucket = google_storage_bucket.fn_source[0].name
  source_archive_object = google_storage_bucket_object.telegram_fn[0].name

  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.alerts[0].id
  }

  environment_variables = {
    TELEGRAM_CHAT_ID   = var.telegram_chat_id
    TELEGRAM_THREAD_ID = var.telegram_thread_id
  }

  secret_environment_variables {
    key        = "TELEGRAM_BOT_TOKEN"
    project_id = var.project_id
    secret     = google_secret_manager_secret.telegram_bot_token[0].secret_id
    version    = "latest"
  }

  depends_on = [
    google_project_service.cloudfunctions,
    google_project_service.cloudbuild,
    google_project_service.pubsub,
    google_secret_manager_secret_iam_member.telegram_token_accessor,
    google_secret_manager_secret_version.telegram_bot_token_v,
  ]
}

# --- Secret Manager for bot token (never in env vars / state) ---

resource "google_secret_manager_secret" "telegram_bot_token" {
  count     = local.telegram_enabled ? 1 : 0
  secret_id = "telegram-bot-token"
  replication {
    user_managed {
      replicas { location = "us-central1" }
    }
  }
}

resource "google_secret_manager_secret_version" "telegram_bot_token_v" {
  count       = local.telegram_enabled ? 1 : 0
  secret      = google_secret_manager_secret.telegram_bot_token[0].id
  secret_data = var.telegram_bot_token
}

# Cloud Functions default SA needs secretAccessor to read the token at
# runtime. The default SA is PROJECT_ID@appspot.gserviceaccount.com.
resource "google_secret_manager_secret_iam_member" "telegram_token_accessor" {
  count     = local.telegram_enabled ? 1 : 0
  secret_id = google_secret_manager_secret.telegram_bot_token[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.project_id}@appspot.gserviceaccount.com"
}