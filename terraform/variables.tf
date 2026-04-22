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