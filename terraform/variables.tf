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