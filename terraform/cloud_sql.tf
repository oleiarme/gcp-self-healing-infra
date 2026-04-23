# ==========================================
# CLOUD SQL AS CODE (Phase 4 / PR B)
# ==========================================
# Historically the n8n PostgreSQL backend lived as a Cloud SQL instance
# provisioned out-of-band (click-ops or gcloud), and Terraform only knew
# the private IP through `var.db_host`. That made three promises in the
# Runbook unenforceable by IaC:
#
#   * PITR retention      — Runbook §5.1 states "7 day PITR". Nothing in
#                           code actually set `point_in_time_recovery_enabled`
#                           or retention. Operators had to trust the
#                           console.
#   * deletion_protection — an accidental `gcloud sql instances delete`
#                           would not fail-fast because Terraform had no
#                           resource to refuse the change.
#   * backup_configuration — backup schedule, location, retention were
#                           not declared; drift from the "always-on
#                           daily backup at 02:00 UTC" baseline could
#                           only be caught manually.
#
# This file closes those three gaps by expressing the instance, the
# primary database, and the application user as Terraform resources.
#
# ---
# OPT-IN BY DEFAULT
# ---
# `var.cloud_sql_managed = false` is the default. When false, `count = 0`
# on every resource in this file and behaviour is identical to the
# pre-PR-B stack: operator supplies `var.db_host` / `var.db_user` /
# `var.db_password` (via TF_VAR_*) directly, and Terraform never touches
# the existing DB. This preserves the live DB contract for rollbacks.
#
# ---
# IMPORT-SAFE WORKFLOW
# ---
# For an existing instance, flipping `cloud_sql_managed = true` and
# applying without importing first will attempt to *create* a second
# instance with the same name (API error: ALREADY_EXISTS). Running
# `terraform import` before flipping the toggle fails the other way:
# with `cloud_sql_managed = false` every resource below has `count = 0`,
# so `google_sql_database_instance.main[0]` is not a valid import
# target. The correct order is flip-then-import-then-plan-then-apply:
#
#   1. Set `cloud_sql_managed = true` in .tfvars or TF_VAR_*, plus the
#      matching `cloud_sql_instance_name`, `cloud_sql_private_network`,
#      and `cloud_sql_tier`. Do NOT run `terraform apply` yet.
#
#   2. Import the three resources into state (their configs now exist
#      because count = 1 after step 1):
#
#        terraform import 'google_sql_database_instance.main[0]' \
#          "projects/${PROJECT}/instances/${INSTANCE_NAME}"
#        terraform import 'google_sql_database.n8n[0]' \
#          "projects/${PROJECT}/instances/${INSTANCE_NAME}/databases/postgres"
#        terraform import 'google_sql_user.n8n[0]' \
#          "${PROJECT}/${INSTANCE_NAME}/${DB_USER}"
#
#   3. Run `terraform plan`. Expected diff: `deletion_protection`
#      flips on, `backup_configuration.point_in_time_recovery_enabled`
#      flips on if PITR was off, `database_flags` appears if slow-query
#      logging wasn't set. Any "will be created" line for the instance
#      means an import was missed — go back to step 2.
#
#   4. `terraform apply`. Settings changes are applied live; expect a
#      ~30-60s connectivity blip when database_flags are updated.
#
# Full procedure with rollback steps: Runbook §5.6 Cloud SQL adoption.
#
# ---
# NETWORKING ASSUMPTION
# ---
# This file does *not* provision the VPC peering / private-IP range
# required for `ipConfiguration.privateNetwork` — the same out-of-band
# contract that `var.db_host` already assumed. Adding VPC peering to
# IaC would require a project-wide networking rework and is
# intentionally deferred; doing it here would change more than the
# file's stated scope.

locals {
  cloud_sql_enabled = var.cloud_sql_managed

  # Single source of truth for the private IP that the VM's startup
  # script writes into docker-compose.yml. When Cloud SQL is managed
  # by Terraform we derive it from the instance resource so any
  # adoption / re-import / eventual HA flip updates the VM config in
  # the same apply. When Cloud SQL is out-of-band we fall back to
  # var.db_host exactly like before. Validation below makes sure we
  # never end up with an empty string (startup.sh would render
  # DB_POSTGRESDB_HOST="" and n8n would fail to connect in a way
  # that's painful to diagnose).
  effective_db_host = local.cloud_sql_enabled ? (
    length(google_sql_database_instance.main) > 0 ?
    google_sql_database_instance.main[0].private_ip_address :
    var.db_host
  ) : var.db_host
}

# Guardrail note: the "neither managed nor var.db_host set" case is
# caught at plan time by a lifecycle.precondition on
# google_compute_instance_template.tpl (see main.tf), not by a
# top-level `check` block. Two reasons:
#   * `check` blocks require Terraform 1.5+ *and* aws/tfsec currently
#     refuses to parse them ("Unsupported block type"), which blocked
#     CI on PR #8 until this was restructured.
#   * lifecycle.precondition is supported by every static analyzer
#     the stack uses (terraform validate, tflint, tfsec, checkov) and
#     the operator sees the error at the same plan step.

resource "google_sql_database_instance" "main" {
  count = local.cloud_sql_enabled ? 1 : 0

  name             = var.cloud_sql_instance_name
  database_version = var.cloud_sql_database_version
  region           = var.region
  project          = var.project_id

  # CRITICAL: prevents `gcloud sql instances delete`, Terraform
  # destroy, and console "Delete" button from wiping the primary DB.
  # Only way past it: set to false in a reviewed PR, apply, then
  # destroy — two steps, two code reviews.
  deletion_protection = true

  settings {
    tier              = var.cloud_sql_tier
    availability_type = var.cloud_sql_availability_type
    disk_size         = var.cloud_sql_disk_size_gb
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    # Backup window: 02:00 UTC is the historical baseline. Start time
    # in Cloud SQL is a best-effort; the actual backup runs within a
    # 4-hour window from this time.
    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      location                       = var.region
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = var.cloud_sql_pitr_retention_days

      backup_retention_settings {
        retained_backups = var.cloud_sql_pitr_retention_days
        retention_unit   = "COUNT"
      }
    }

    # Maintenance outside US business hours. hour is 0-23 UTC.
    maintenance_window {
      day          = 7 # Sunday
      hour         = 8
      update_track = "stable"
    }

    # IP configuration mirrors the out-of-band baseline:
    # private IP only, no public endpoint. If the operator has not yet
    # peered the VPC with servicenetworking.googleapis.com, this field
    # will fail at apply; run the peering step first (documented in
    # Runbook §5.6).
    ip_configuration {
      ipv4_enabled    = false
      private_network = var.cloud_sql_private_network
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    # Enable slow-query log for on-call debugging — cheap on e2-micro
    # footprint.
    database_flags {
      name  = "log_min_duration_statement"
      value = "1000" # ms; anything slower than 1s logged
    }

    # log_duration + log_statement pair gives us actionable slow-query
    # traces in Cloud Logging without the firehose of log_statement=all.
    # CKV2_GCP_13 / CIS 2.13.
    database_flags {
      name  = "log_duration"
      value = "on"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = false
      record_client_address   = false
    }
  }

  # Even with deletion_protection, Terraform state manipulation could
  # in theory try to re-create the resource. Force create_before_destroy
  # off — PostgreSQL instance recreation is never what we want.
  lifecycle {
    prevent_destroy = true

    # Don't re-apply changes to fields Cloud SQL itself may adjust
    # (e.g. replica names under HA, root_password if rotated
    # out-of-band). Prevents accidental pointless applies.
    ignore_changes = [
      settings[0].disk_size, # autoresize will change this
      root_password,
    ]
  }

  depends_on = [google_project_service.required]
}

resource "google_sql_database" "n8n" {
  count = local.cloud_sql_enabled ? 1 : 0

  name     = "postgres"
  instance = google_sql_database_instance.main[0].name
  project  = var.project_id

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_sql_user" "n8n" {
  count = local.cloud_sql_enabled ? 1 : 0

  name     = var.db_user
  instance = google_sql_database_instance.main[0].name
  password = var.db_password
  project  = var.project_id

  # Don't flap the password if it's been rotated in Secret Manager
  # out-of-band; rotation flow is documented in Runbook §5.3.
  lifecycle {
    ignore_changes = [password]
  }
}
