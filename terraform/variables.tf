variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for single-zone resources outside the MIG (reserved for compatibility). Since Phase 4 the MIG itself is regional and distributed across all three us-central1 zones (a/b/f)."
  type        = string
  default     = "us-central1-a"
}

# --------------------------------------------------------
# Resilience & DR (Phase 4 of docs/slo-roadmap)
# --------------------------------------------------------
# mig_zones removed to fix tflint warning.
# Since we use a zonal persistent disk, the MIG must be pinned to var.zone
# to ensure the disk can be attached to the VM.


variable "billing_account_id" {
  description = "GCP billing account ID the project is attached to (format: 'AAAAAA-BBBBBB-CCCCCC'). When set, enables the google_billing_budget cost guardrail; when empty (default), the budget resource is not created and cost alerting is left off. Find the ID via `gcloud beta billing accounts list`."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly budget cap in USD for the billing account alert. Alerts fire at 50/90/100% of this amount. Defaults to $5 to keep the Free-Tier envelope narrow — any spend above this is either an escape (e.g. surprise egress) or a scaling decision that should be explicit."
  type        = number
  default     = 5
}

variable "db_host" {
  description = "Cloud SQL private IP address. Required when var.cloud_sql_managed is false (out-of-band DB); ignored when var.cloud_sql_managed is true (Terraform reads the private IP from the managed google_sql_database_instance instead)."
  type        = string
  sensitive   = false
  default     = ""
}

# --------------------------------------------------------
# Cloud SQL as code (Phase 4 / PR B)
# --------------------------------------------------------
# All of these only take effect when cloud_sql_managed = true.
# Keeping them declared so operators can set them preemptively
# before flipping the toggle without a second plan/apply round.

variable "cloud_sql_managed" {
  description = "Opt-in: manage the PostgreSQL Cloud SQL instance via Terraform. Defaults to false so existing stacks are unaffected. See terraform/cloud_sql.tf for the import-safe workflow before flipping this to true against an existing instance."
  type        = bool
  default     = false
}

variable "cloud_sql_instance_name" {
  description = "Cloud SQL instance name. Must match the existing instance's name when adopting an out-of-band DB via terraform import."
  type        = string
  default     = "n8n-postgres"
}

variable "cloud_sql_database_version" {
  description = "Cloud SQL PostgreSQL major version string (e.g. 'POSTGRES_15'). Must match the existing instance when importing."
  type        = string
  default     = "POSTGRES_15"
}

variable "cloud_sql_tier" {
  description = "Cloud SQL machine type. 'db-f1-micro' stays inside Cloud SQL free tier; upgrade to 'db-custom-1-3840' or larger if n8n job load outgrows it."
  type        = string
  default     = "db-f1-micro"
}

variable "cloud_sql_availability_type" {
  description = "'ZONAL' (single zone, cheaper) or 'REGIONAL' (synchronous standby, HA — leaves Free Tier). Phase 4 keeps ZONAL consistent with the single-VM MIG topology."
  type        = string
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.cloud_sql_availability_type)
    error_message = "cloud_sql_availability_type must be either ZONAL or REGIONAL."
  }
}

variable "cloud_sql_disk_size_gb" {
  description = "Cloud SQL persistent disk size in GB. disk_autoresize is enabled; this is the starting size."
  type        = number
  default     = 10
}

variable "cloud_sql_pitr_retention_days" {
  description = "Days of point-in-time-recovery transaction log retention AND number of automatic backups kept. Cloud SQL allows 1-7."
  type        = number
  default     = 7

  validation {
    condition     = var.cloud_sql_pitr_retention_days >= 1 && var.cloud_sql_pitr_retention_days <= 7
    error_message = "cloud_sql_pitr_retention_days must be between 1 and 7 (Cloud SQL API limit)."
  }
}

variable "cloud_sql_private_network" {
  description = "VPC network self-link (projects/PROJECT/global/networks/NAME) that is peered with servicenetworking.googleapis.com for the Cloud SQL private IP. Must exist before apply when cloud_sql_managed is true."
  type        = string
  default     = ""
}

variable "db_user" {
  description = "PostgreSQL username for n8n"
  type        = string
  sensitive   = false
}

variable "db_password" {
  description = "PostgreSQL password — stored in Secret Manager, not used directly"
  type        = string
  sensitive   = true
}

variable "n8n_encryption_key" {
  description = "n8n encryption key (32+ random chars) — stored in Secret Manager"
  type        = string
  sensitive   = true
}

variable "CF_TUNNEL_TOKEN" {
  description = "Cloudflare Tunnel token — stored in Secret Manager"
  type        = string
  sensitive   = true
}

# --------------------------------------------------------
# Observability (Phase 2 of docs/slo-roadmap)
# --------------------------------------------------------

variable "n8n_public_host" {
  description = "Public FQDN of the n8n deployment (no scheme, no path). Probed by the SLI uptime check on https://<host>/healthz. Example: 'n8n.example.com'."
  type        = string
}

variable "oncall_email" {
  description = "Email address that receives SLO burn-rate and startup-CRITICAL alerts."
  type        = string
}

# Slack delivery — Phase 4 follow-up. Uses the native type = "slack"
# notification channel, which takes an OAuth bot token in
# sensitive_labels.auth_token and a channel name in labels.channel_name.
# Unlike an incoming-webhook URL (which embeds its own auth), the OAuth
# token is stored server-side by Cloud Monitoring and never round-trips
# through state in plaintext. Both vars default to "" so the Slack
# channel is only provisioned when operators explicitly opt in by
# setting TF_VAR_slack_auth_token.
variable "slack_auth_token" {
  description = "Slack bot OAuth token (xoxb-...). Leave empty to disable Slack notification channel. When set, must have chat:write permission on var.slack_channel."
  type        = string
  sensitive   = true
  default     = ""
}

variable "slack_channel" {
  description = "Slack channel name (with leading #) that receives SLO + startup + budget alerts. Ignored if var.slack_auth_token is empty."
  type        = string
  default     = "#n8n-ops"
}

# --------------------------------------------------------
# Container image pinning (Phase 3 of docs/slo-roadmap)
# --------------------------------------------------------
# Both images are pinned by SHA256 digest in addition to the human-readable
# tag, so a re-issued tag (e.g. cloudflared rebuilds the same tag with new
# layers) cannot silently change what runs on the VM.
#
# Digests are refreshed by .github/workflows/digest-refresh.yml (weekly
# cron + manual dispatch). That workflow uses `crane digest` to resolve
# each image, runs `terraform validate`, and opens a review PR via
# peter-evans/create-pull-request when either digest has moved.
#
# To refresh manually from a checkout:
#   bash scripts/refresh-digests.sh          # bumps in-place + exit 0
# Or resolve the digest by hand:
#   crane digest <image>:<tag>                         # crane CLI
#   docker buildx imagetools inspect <image>:<tag>     # local docker
#   curl -sI -H "Accept: application/vnd.oci.image.index.v1+json" \
#        https://<registry>/v2/<repo>/manifests/<tag>  # registry HTTP API

variable "n8n_image" {
  description = "Pinned n8n container image (tag@digest). Managed by Renovate; release notes: https://github.com/n8n-io/n8n/releases"
  type        = string
  default     = "docker.n8n.io/n8nio/n8n:2.17.7@sha256:a293b89bac876872a0c1ef0fbbb7ce056aa2d215f62917acf032ecb8010199af"
}

variable "cloudflared_image" {
  description = "cloudflared container image, including registry, repo, tag and SHA256 digest. Used by scripts/startup.sh in the docker-compose service definition."
  type        = string
  default     = "cloudflare/cloudflared:2026.3.0@sha256:6b599ca3e974349ead3286d178da61d291961182ec3fe9c505e1dd02c8ac31b0"
}

# --------------------------------------------------------
# Workload Identity Federation guardrails (Phase 3)
# --------------------------------------------------------
# These document the attribute condition that must be applied to the WIF
# provider that GitHub Actions assumes. The provider is created
# out-of-band (one-shot bootstrap, not in this codebase); Terraform
# surfaces the expected condition string via `terraform output
# wif_attribute_condition` so an operator can copy-paste it straight
# into `gcloud iam workload-identity-pools providers update-oidc`.
variable "wif_allowed_repository" {
  description = "Fully-qualified GitHub repository (owner/name) allowed to assume the WIF provider. Set per-fork in .tfvars or TF_VAR_wif_allowed_repository."
  type        = string
}

variable "github_repository_url" {
  description = "HTTPS URL of this repository on GitHub. Used to render runbook/dashboard links in alert policies. Set per-fork in .tfvars or TF_VAR_github_repository_url (e.g. https://github.com/<owner>/gcp-self-healing-infra)."
  type        = string
}

variable "wif_allowed_ref" {
  description = "Fully-qualified Git ref allowed to assume the WIF provider (e.g. 'refs/heads/main')."
  type        = string
  default     = "refs/heads/main"
}

# Phase 4 follow-up: optional enforcement of the WIF attribute condition
# via a data source + lifecycle precondition. If both IDs are provided,
# Terraform fetches the actual attribute_condition from the running WIF
# provider and refuses to plan when it drifts from the canonical string
# derived from wif_allowed_repository / wif_allowed_ref. If either is
# empty, enforcement is skipped and the output-only documentation from
# Phase 3 is the only safeguard.
variable "wif_pool_id" {
  description = "Short ID of the existing Workload Identity Pool (not the full resource name). Example: 'github-actions-pool'. Leave empty to skip enforcement."
  type        = string
  default     = ""
}

variable "wif_provider_id" {
  description = "Short ID of the OIDC provider inside var.wif_pool_id. Example: 'github-actions'. Leave empty to skip enforcement."
  type        = string
  default     = ""
}


variable "backup_bucket_name" {
  type = string

  validation {
    condition     = length(var.backup_bucket_name) > 0
    error_message = "backup_bucket_name must not be empty"
  }
}

variable "telegram_bot_token" {
  description = "Telegram bot token"
  type        = string
  sensitive   = true
  default     = ""
}

variable "telegram_chat_id" {
  description = "Telegram chat id"
  type        = string
  default     = ""
}

variable "telegram_thread_id" {
  description = "Telegram message_thread_id"
  type        = string
  default     = ""
}
variable "disk_size_gb" {
  description = "Size of the persistent data disk for Postgres"
  type        = number
  default     = 10
}

variable "n8n_image_tag" {
  description = "Tag for the n8n image"
  type        = string
  default     = "2.17.7"
}

variable "cloudflared_image_tag" {
  description = "Tag for the cloudflared image"
  type        = string
  default     = "2026.3.0"
}
