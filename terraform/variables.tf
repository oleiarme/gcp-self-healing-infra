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
  description = "GCP zone for MIG (us-central1-a for Free Tier e2-micro)"
  type        = string
  default     = "us-central1-a"
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
# layers) cannot silently change what runs on the VM. Dependabot
# (.github/dependabot.yml) keeps both digests fresh.
#
# To refresh a digest manually:
#   docker buildx imagetools inspect <image>:<tag>     # local docker
#   crane digest <image>:<tag>                         # crane CLI
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