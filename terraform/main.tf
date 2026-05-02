terraform {
  required_version = ">= 1.0"

  # Backend настраивается через -backend-config=backend.conf
  # Placeholder bucket — перезаписывается -backend-config="bucket=..." в CI
  backend "gcs" {
    bucket  = "idealist-426118-tf-state"
    prefix  = "n8n"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}


resource "random_id" "bucket_suffix" {
  byte_length = 2
}

resource "google_project_service" "required" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    # Phase 4: google_billing_budget goes through the billingbudgets API.
    "billingbudgets.googleapis.com",
    # Phase 4 / PR B: google_sql_database_instance needs the Cloud SQL
    # Admin API. Enabling it unconditionally (not gated on
    # var.cloud_sql_managed) is cheap — the API has no per-enable cost —
    # and avoids a two-step apply when flipping the toggle.
    "sqladmin.googleapis.com",
    # Phase 4 / PR B: Cloud SQL private IP requires a VPC peering with
    # the Service Networking API. Enabling the API here still leaves
    # peering as an out-of-band step (same as var.db_host assumption),
    # but makes the private IP creation path work once peering is in
    # place.
    "servicenetworking.googleapis.com",
  ])

  service = each.key
}

resource "google_service_account" "vm_sa" {
  account_id   = "n8n-app-sa"
  display_name = "n8n VM Service Account"

  # Re-creating the SA would orphan every secretmanager.secretAccessor
  # binding, locking the running VM out of Secret Manager and breaking
  # n8n on the next restart. Force a deliberate two-step destroy if we
  # ever genuinely need to remove it.
  lifecycle {
    prevent_destroy = false
  }
}

# ==========================================
# 1.0 PROJECT-LEVEL IAM (least-privilege)
# ==========================================
# Historically the VM ran with `scopes = ["cloud-platform"]` and no
# explicit IAM bindings, which meant the VM SA inherited whatever roles
# anyone happened to grant at the project level. The OAuth scope
# `cloud-platform` is still set on the VM (see google_compute_instance_template
# below) because Secret Manager has no narrower scope and `metadata.startup-script`
# uses Application Default Credentials to read secrets — but the *effective*
# permissions are now the intersection of (cloud-platform scope) ∩ (the
# minimal IAM bindings declared here). Adding a new permission is now an
# explicit, code-reviewed change rather than an accidental side effect.
#
# Bindings:
#   * roles/logging.logWriter   — Ops Agent ships /var/log/startup.log
#                                 to Cloud Logging (used by the
#                                 n8n/startup_critical log-based metric).
#   * roles/monitoring.metricWriter — write custom metrics later (Phase
#                                 4 / Phase 6 chaos drill metrics). Cheap
#                                 to grant up-front; avoids a re-apply
#                                 just to add it.
# Secret Manager access is granted per-secret (roles/secretmanager.secretAccessor)
# below — never project-wide — so a future second secret in this project
# is opt-in for this VM rather than automatic.

resource "google_project_iam_member" "vm_sa_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vm_sa.email}"
}

resource "google_project_iam_member" "vm_sa_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.vm_sa.email}"
}

# ==========================================
# 1.1 WIF ATTRIBUTE CONDITION ENFORCEMENT (Phase 4 follow-up)
# ==========================================
# Phase 3 emitted the canonical attribute_condition as a Terraform output
# so operators could copy-paste it into `gcloud iam workload-identity-pools
# providers update-oidc`. That is documentation only — it does not detect
# drift if the condition is edited out-of-band, or if the pool was
# bootstrapped without it. This data source + precondition closes that gap:
# when var.wif_pool_id / var.wif_provider_id are both set, Terraform reads
# the live attribute_condition and refuses to plan if it drifts from the
# expected string. When either var is empty, the data source is skipped
# and the output-only documentation is the sole safeguard (unchanged
# behaviour for repos that haven't opted in).
locals {
  startup_hash = filemd5("${path.module}/../scripts/startup_cos.sh")
  wif_enforcement_enabled = var.wif_pool_id != "" && var.wif_provider_id != ""
  wif_expected_condition  = "assertion.repository == \"${var.wif_allowed_repository}\" && assertion.ref == \"${var.wif_allowed_ref}\""

  # Short digest for tagging AR images consistently with CI
  n8n_digest_short = substr(element(split("@sha256:", var.n8n_image), 1), 0, 8)
  cf_digest_short  = substr(element(split("@sha256:", var.cloudflared_image), 1), 0, 8)
  ar_prefix        = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
  n8n_ar_image     = "${local.ar_prefix}/n8n:${var.n8n_image_tag}-${local.n8n_digest_short}"
  cf_ar_image      = "${local.ar_prefix}/cloudflared:${var.cloudflared_image_tag}-${local.cf_digest_short}"
}

data "google_iam_workload_identity_pool_provider" "github" {
  count                              = local.wif_enforcement_enabled ? 1 : 0
  project                            = var.project_id
  workload_identity_pool_id          = var.wif_pool_id
  workload_identity_pool_provider_id = var.wif_provider_id

  lifecycle {
    postcondition {
      condition     = self.attribute_condition == local.wif_expected_condition
      error_message = <<-EOM
        WIF attribute_condition drift detected on provider '${var.wif_provider_id}' in pool '${var.wif_pool_id}'.
        expected: ${local.wif_expected_condition}
        actual:   ${self.attribute_condition}
        Fix with: gcloud iam workload-identity-pools providers update-oidc ${var.wif_provider_id} \
          --location=global --workload-identity-pool=${var.wif_pool_id} --project=${var.project_id} \
          --attribute-condition='${local.wif_expected_condition}'
        Or unset var.wif_pool_id / var.wif_provider_id to disable enforcement.
      EOM
    }
  }
}

# ==========================================
# 1. SECRETS MANAGEMENT
# ==========================================

# 1.1 DB Password
resource "google_secret_manager_secret" "db_password" {
  secret_id = "n8n-db-secret"
  replication {
    user_managed {
      replicas { location = "us-central1" }
    }
  }

  # `terraform destroy` must never blow away a credential the running VM
  # depends on — recreating the secret resource would invalidate IAM
  # bindings and secret_versions, dropping n8n into a Postgres-auth-fail
  # crash loop. Forces an explicit two-step removal (`terraform state rm`
  # then destroy) for legitimate decommissioning.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "db_password_v" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

resource "google_secret_manager_secret_iam_member" "access" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm_sa.email}"
}

# 1.2 n8n Encryption Key
resource "google_secret_manager_secret" "n8n_key" {
  secret_id = "n8n-encryption-key"
  replication {
    user_managed {
      replicas { location = "us-central1" }
    }
  }

  # See note on db_password: recreating the encryption key secret would
  # invalidate every credential n8n has stored (OAuth tokens for
  # connectors etc.) — this is unrecoverable without a backup of the
  # secret. prevent_destroy forces a deliberate manual workflow.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "n8n_key_v" {
  secret      = google_secret_manager_secret.n8n_key.id
  secret_data = var.n8n_encryption_key
}

resource "google_secret_manager_secret_iam_member" "n8n_key_access" {
  secret_id = google_secret_manager_secret.n8n_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm_sa.email}"
}



# 1.3 Cloudflare Tunnel Token
resource "google_secret_manager_secret" "cf_token" {
  secret_id = "n8n-cf-token"
  replication {
    user_managed {
      replicas { location = "us-central1" }
    }
  }

  # See note on db_password.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "cf_token_v" {
  secret      = google_secret_manager_secret.cf_token.id
  secret_data = var.CF_TUNNEL_TOKEN
}

resource "google_secret_manager_secret_iam_member" "cf_token_access" {
  secret_id = google_secret_manager_secret.cf_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm_sa.email}"
}

# ==========================================
# 1.5 BACKUP STORAGE
# ==========================================
# GCS bucket for n8n Postgres backups. The lifecycle rule auto-deletes
# objects older than 7 days, keeping storage under the 5 GB Free-Tier
# cap (~1 GB at 144 backups/day × 7 days × ~1 MB each).
# IMPORTANT: existing bucket must be imported before first apply:
#   terraform import google_storage_bucket.backup <bucket-name>

resource "google_storage_bucket" "backup" {
  name                        = "${var.project_id}-backup-${random_id.bucket_suffix.hex}"
  location                    = "US-CENTRAL1"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = true
  }

  logging {
    log_bucket        = google_storage_bucket.logs.name
    log_object_prefix = "backup-access"
  }

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "backup_writer" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm_sa.email}"
}

resource "google_storage_bucket" "logs" {
  name                        = "${var.backup_bucket_name}-logs"
  location                    = "US-CENTRAL1"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = true
  }

  logging {
    log_bucket        = google_storage_bucket.logs_audit.name
    log_object_prefix = "logs-access"
  }

}

//checkov:skip=CKV_GCP_62: Terminal audit bucket
resource "google_storage_bucket" "logs_audit" {
  name                        = "${var.backup_bucket_name}-logs-audit"
  location                    = "US-CENTRAL1"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }
}

# ==========================================
# 1.6 ARTIFACT REGISTRY & PERSISTENT DATA
# ==========================================

# checkov:skip=CKV_GCP_84: Artifact Registry CMK encryption is overkill for a Free Tier project
resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = "n8n-docker"
  format        = "DOCKER"
  description   = "Docker mirror for n8n/cloudflared to bypass Docker Hub rate limits and speed up cold starts"
}

resource "google_project_iam_member" "vm_sa_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.vm_sa.email}"
}

# checkov:skip=CKV_GCP_37: CSEK encryption is overkill for a Free Tier project; Google-managed encryption is sufficient
resource "google_compute_disk" "data" {
  name = "google-n8n-data"
  type = "pd-standard"
  zone = var.zone
  size = var.disk_size_gb

  lifecycle {
    prevent_destroy = false
  }
}

# ==========================================
# 2. COMPUTE RESOURCES

# ==========================================

resource "google_compute_health_check" "hc" {
  name = "n8n-health-check"

  http_health_check {
    port         = 8080
    request_path = "/"
  }

  check_interval_sec  = 10
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 7
}

resource "google_compute_instance_template" "tpl" {
  # Public-IP NAT exception (checkov:skip=CKV_GCP_40):
  # The VM runs a Cloudflare Tunnel as its sole ingress path — there are no
  # open listening ports and GCP firewall keeps the default-VPC inbound
  # ruleset. The public IP is used strictly for OUTBOUND traffic: apt,
  # docker pull, Cloud Logging, Cloud Monitoring, and the cloudflared
  # outbound tunnel connection. Moving this to Cloud NAT would satisfy
  # CKV_GCP_40 but adds a recurring NAT gateway cost that breaks the
  # Free-Tier envelope this repo is constrained to. Shielded VM + blocked
  # project-wide SSH keys cover the residual VM-level risk.
  # checkov:skip=CKV_GCP_40: public-IP is outbound-only; NAT violates Free-Tier budget
  depends_on = [
    google_secret_manager_secret.db_password,
    google_secret_manager_secret.n8n_key,
    google_secret_manager_secret.cf_token
  ]
  name = "n8n-${substr(local.startup_hash, 0, 6)}"
  machine_type = "e2-micro"
  tags         = ["n8n"]


  disk {
    source_image         = "cos-cloud/cos-stable"
    disk_size_gb         = 30
    auto_delete          = true
    boot                 = true
  }

  disk {
    source      = google_compute_disk.data.name
    auto_delete = false
    boot        = false
    device_name = "n8n-data"
  }

  # Shielded VM (Secure Boot + vTPM + integrity monitoring). Free-Tier
  # compatible; protects against boot-time rootkits and kernel-level
  # tampering. Closes Checkov CKV_GCP_39.
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  network_interface {
    network = "default"

    access_config {
      network_tier = "STANDARD"
    }
  }

  service_account {
    email = google_service_account.vm_sa.email
    # `cloud-platform` looks broad but is required because Secret Manager
    # has no narrower OAuth scope (see Google's GCE access-scope docs).
    # Effective permission set is the intersection of this scope and the
    # explicit IAM role bindings on google_service_account.vm_sa
    # (roles/logging.logWriter, roles/monitoring.metricWriter,
    # per-secret roles/secretmanager.secretAccessor) — see the
    # "PROJECT-LEVEL IAM" section above.
    scopes = ["cloud-platform"]
  }

  metadata = {
    # Block OS-login / project-wide SSH keys. Runbook procedures do not
    # rely on interactive SSH — everything is either a `terraform apply`
    # or a serial-console break-glass. Closes Checkov CKV_GCP_32.
    block-project-ssh-keys = "true"
    startup-script = file("${path.module}/../scripts/startup_cos.sh")
    config_db_user           = var.db_user
config_db_name           = local.cloud_sql_enabled ? google_sql_database.n8n[0].name : "postgres"
config_db_secret         = google_secret_manager_secret.db_password.secret_id
config_n8n_key_secret    = google_secret_manager_secret.n8n_key.secret_id
config_cf_token_secret   = google_secret_manager_secret.cf_token.secret_id

config_n8n_image         = var.n8n_image
config_cloudflared_image = var.cloudflared_image

config_n8n_ar_image      = local.n8n_ar_image
config_cf_ar_image       = local.cf_ar_image

config_db_port           = "5432"
config_n8n_host          = var.n8n_public_host
config_backup_bucket     = "n8n-backups-idealist426118"
    startup-script-hash = local.startup_hash
    
  }

  lifecycle {
    create_before_destroy = true

    # PR B guardrail: fail plan if the VM template would be rendered
    # with an empty DB host. Either var.cloud_sql_managed must be true
    # (and the managed instance will produce a private_ip_address) or
    # var.db_host must be non-empty (out-of-band contract). An empty
    # local.effective_db_host silently renders DB_POSTGRESDB_HOST=""
    # into docker-compose.yml, producing an opaque n8n connect error
    # after the VM boots — much harder to diagnose than a failing
    # plan.
    precondition {
      condition     = local.effective_db_host != ""
      error_message = "Either set var.cloud_sql_managed = true (and import the existing instance per terraform/cloud_sql.tf) or provide var.db_host for the out-of-band Cloud SQL instance."
    }
  }
}

# ==========================================
# Managed Instance Group (regional, Phase 4)
# ==========================================
# Replaces the previous zonal google_compute_instance_group_manager. The
# MIG still runs a single e2-micro (target_size=1, Free Tier compliant),
# but it is now free to place that VM in any zone of us-central1 listed
# in var.mig_zones. Practical effect on SLO: a zonal outage (whole AZ
# goes dark) no longer keeps the VM dead — MIG's self-healing path tries
# a surviving zone on the next replacement. Expected zonal-failover MTTR
# is the same as cold start (≆17 min worst case) because the replacement
# path always runs full startup.sh on a fresh VM.
#
# State-migration note: on first apply the old zonal resource is
# destroyed and this regional resource is created. Brief downtime during
# the cutover is expected; see Runbook §Backup & DR for the procedure.
resource "google_compute_region_instance_group_manager" "mig" {
  name                      = "n8n-mig"
  base_instance_name        = "n8n"
  region                    = var.region
  distribution_policy_zones = [var.zone]
  target_size               = 1

  version {
    instance_template = google_compute_instance_template.tpl.id
  }

  stateful_disk {
    device_name = "n8n-data"
    delete_rule = "NEVER"
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.hc.id
    initial_delay_sec = 1200
  }

  update_policy {
    type                         = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 0
    max_unavailable_fixed        = 1
    replacement_method           = "RECREATE"
    instance_redistribution_type = "NONE"
  }
}

# ==========================================
# Cost guardrail (Phase 4)
# ==========================================
resource "google_billing_budget" "monthly_cap" {
  # Opt-in: leaving var.billing_account_id empty disables the budget
  # entirely. The rest of the stack is project-scoped and does not need
  # billing-account-level metadata, so requiring the ID would have
  # forced operators to provision a secret they may not want. When the
  # ID is provided, the budget provisions normally.
  count           = var.billing_account_id != "" ? 1 : 0
  billing_account = var.billing_account_id
  display_name    = "n8n self-healing infra — monthly cap"

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }

  amount {
    # Billing budget amount is a google.type.Money: integer dollars in
    # `units` and the fractional part in `nanos` (billionths of a dollar).
    # Splitting var.monthly_budget_usd (a `number`) with floor + fraction
    # preserves decimals; a previous revision used `tostring(var.x)` which
    # silently dropped anything after the decimal point (e.g. $5.50 → $5).
    specified_amount {
      currency_code = "USD"
      units         = tostring(floor(var.monthly_budget_usd))
      nanos         = floor((var.monthly_budget_usd - floor(var.monthly_budget_usd)) * 1000000000)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  # Reuse the same notification channel set as every SLO / startup /
  # log-ingestion alert uses (see monitoring.tf). local.all_notification_channels
  # resolves to email-only when Slack is opted out and email + Slack
  # when var.slack_auth_token is provided, keeping the delivery path
  # consistent with Runbook §6.1 ("monthly_cap budget 90% → P2 → Slack
  # #n8n-ops"). Opting into pubsubTopic or additional channels is left
  # for a later phase.
  all_updates_rule {
    monitoring_notification_channels = local.all_notification_channels
    disable_default_iam_recipients   = false
  }

  depends_on = [google_project_service.required]
}


resource "google_compute_firewall" "allow_health_check" {
  name    = "allow-health-check"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16"
  ]

  target_tags = ["n8n"]
}
