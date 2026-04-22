# Instance Group (regional since Phase 4)
output "mig_name" {
  description = "Managed Instance Group name"
  value       = google_compute_region_instance_group_manager.mig.name
}

output "mig_region" {
  description = "Region the MIG operates in (us-central1 for Free Tier)"
  value       = google_compute_region_instance_group_manager.mig.region
}

output "mig_distribution_zones" {
  description = "Zones the regional MIG may place its single VM in. On a zonal outage the VM self-heals into a surviving zone."
  value       = google_compute_region_instance_group_manager.mig.distribution_policy_zones
}

output "instance_template" {
  description = "Instance template self-link (use to create golden disk from this)"
  value       = google_compute_region_instance_group_manager.mig.version[0].instance_template
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

# Observability (Phase 2) — IDs needed for Runbook links and dashboard URLs
output "uptime_check_id" {
  description = "Uptime check identifier that is the SLI source for SLO burn-rate alerts"
  value       = google_monitoring_uptime_check_config.n8n.uptime_check_id
}

output "alert_policy_fast_burn" {
  description = "Fast-burn SLO alert policy resource name (use to link in Runbook / PagerDuty)"
  value       = google_monitoring_alert_policy.slo_fast_burn.name
}

output "alert_policy_slow_burn" {
  description = "Slow-burn SLO alert policy resource name"
  value       = google_monitoring_alert_policy.slo_slow_burn.name
}

output "alert_policy_startup_critical" {
  description = "Startup-CRITICAL log-based alert policy resource name"
  value       = google_monitoring_alert_policy.startup_critical.name
}

output "dashboard_id" {
  description = "Cloud Monitoring dashboard resource name for the n8n SLO dashboard"
  value       = google_monitoring_dashboard.n8n_slo.id
}

# Security posture (Phase 3) — emit the canonical WIF attribute condition so
# an operator can copy-paste it into `gcloud iam workload-identity-pools
# providers update-oidc …`. The WIF pool itself lives out-of-band (one-shot
# bootstrap) so Terraform cannot enforce this, but surfacing the expected
# condition keeps the source of truth in this repo.
output "wif_attribute_condition" {
  description = "Required attribute_condition on the WIF OIDC provider that GitHub Actions assumes. Paste into `gcloud iam workload-identity-pools providers update-oidc`."
  value       = "assertion.repository == \"${var.wif_allowed_repository}\" && assertion.ref == \"${var.wif_allowed_ref}\""
}

# Resilience & DR (Phase 4)
output "billing_budget_name" {
  description = "Resource name of the monthly spend cap billing budget. Edit the thresholds / amount by changing var.monthly_budget_usd and re-applying."
  value       = google_billing_budget.monthly_cap.name
}