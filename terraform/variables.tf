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