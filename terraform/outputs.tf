# Instance Group
output "mig_name" {
  description = "Managed Instance Group name"
  value       = google_compute_instance_group_manager.mig.name
}

output "mig_zone" {
  description = "MIG zone"
  value       = google_compute_instance_group_manager.mig.zone
}

output "instance_template" {
  description = "Instance template self-link (use to create golden disk from this)"
  value       = google_compute_instance_group_manager.mig.version.0.instance_template
}

# Health Check — use these for Cloud Monitoring alerting
output "health_check_name" {
  description = "GCP health check name for alert policy setup"
  value       = google_compute_health_check.hc.name
}

output "health_check_self_link" {
  description = "Full health check resource URI for Terraform references"
  value       = google_compute_health_check.hc.self_link
}

# Service Account — needed for IAM, logs, alerting
output "vm_service_account_email" {
  description = "VM service account email (use for log-based alerting)"
  value       = google_service_account.vm_sa.email
}

# Secrets — useful for rotation procedures (Runbook.md Scenario 3)
output "secret_names" {
  description = "Secret Manager secret IDs for rotation"
  value = {
    db_password     = google_secret_manager_secret.db_password.secret_id
    n8n_encryption  = google_secret_manager_secret.n8n_key.secret_id
    cf_tunnel_token = google_secret_manager_secret.cf_token.secret_id
  }
}

# Deployment info
output "deployment_timestamp" {
  description = "Terraform apply timestamp — use for change correlation"
  value       = timestamp()
}