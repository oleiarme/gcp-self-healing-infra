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
# Zones the regional MIG is allowed to place the single VM in. Free Tier
# still applies: at any instant exactly one e2-micro runs, anywhere in
# us-central1. But on a zonal incident the MIG relocates to a surviving
# zone, which is the entire point of moving off the old single-zone
# google_compute_instance_group_manager.
variable "mig_zones" {
  description = "Zones the regional MIG may place its single VM in. Must all be within var.region. For us-central1 the Free-Tier-eligible zones are a/b/f."
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b", "us-central1-f"]
}

variable "billing_account_id" {
  description = "GCP billing account ID the project is attached to (format: 'AAAAAA-BBBBBB-CCCCCC'). Required to create the google_billing_budget. Find via `gcloud beta billing accounts list`."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly budget cap in USD for the billing account alert. Alerts fire at 50/90/100% of this amount. Defaults to $5 to keep the Free-Tier envelope narrow — any spend above this is either an escape (e.g. surprise egress) or a scaling decision that should be explicit."
  type        = number
  default     = 5
}

variable "db_host" {
  description = "Cloud SQL private IP address"
  type        = string
  sensitive   = false
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

# NOTE: TF_VAR_slack_webhook_url is intentionally NOT wired in this phase.
# A Slack incoming webhook URL is itself the auth credential, so stuffing
# it into a google_monitoring_notification_channel "webhook_tokenauth"
# labels.url leaks the secret through Terraform state and the Cloud
# Monitoring API. Slack delivery will be added in a later phase using the
# native type = "slack" channel with an OAuth token in sensitive_labels.

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
  description = "n8n container image, including registry, repo, tag and SHA256 digest. Used by scripts/startup.sh in the docker-compose service definition."
  type        = string
  default     = "docker.n8n.io/n8nio/n8n:2.16.1@sha256:ad20607cdd24bac004ec44804b6b8ded9a2fbf92ed46c4496bf007762c883af2"
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
  description = "Fully-qualified GitHub repository (owner/name) allowed to assume the WIF provider."
  type        = string
  default     = "kwonvkim-collab/gcp-self-healing-infra"
}

variable "wif_allowed_ref" {
  description = "Fully-qualified Git ref allowed to assume the WIF provider (e.g. 'refs/heads/main')."
  type        = string
  default     = "refs/heads/main"
}