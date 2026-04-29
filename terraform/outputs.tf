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
# bootstrap) so Terraform cannot enforce this by default, but surfacing the
# expected condition keeps the source of truth in this repo.
output "wif_attribute_condition" {
  description = "Required attribute_condition on the WIF OIDC provider that GitHub Actions assumes. Paste into `gcloud iam workload-identity-pools providers update-oidc`."
  value       = local.wif_expected_condition
}

# Phase 4 follow-up — surface the live attribute_condition when the
# optional enforcement data source is active (var.wif_pool_id /
# var.wif_provider_id both set). Also pins the data source to an actual
# consumer so tflint does not report it as unused; the postcondition on
# the data source itself is where the real drift detection happens. When
# enforcement is disabled, this is null.
output "wif_live_attribute_condition" {
  description = "Live attribute_condition read from the WIF provider when optional enforcement is enabled; null otherwise. Diverging from wif_attribute_condition means drift — the same check runs as a postcondition during plan."
  value       = local.wif_enforcement_enabled ? data.google_iam_workload_identity_pool_provider.github[0].attribute_condition : null
}

# Cloud SQL (Phase 4 / PR B)
output "cloud_sql_instance_name" {
  description = "Name of the Terraform-managed Cloud SQL instance. Null when var.cloud_sql_managed is false (out-of-band DB)."
  value       = length(google_sql_database_instance.main) > 0 ? google_sql_database_instance.main[0].name : null
}

output "cloud_sql_connection_name" {
  description = "Cloud SQL connection name (project:region:instance) for the managed instance. Use with the Cloud SQL Auth Proxy. Null when var.cloud_sql_managed is false."
  value       = length(google_sql_database_instance.main) > 0 ? google_sql_database_instance.main[0].connection_name : null
}

output "cloud_sql_private_ip" {
  description = "Private IP address the VM uses to reach the managed Cloud SQL instance. Null when var.cloud_sql_managed is false (in that case var.db_host is used verbatim)."
  value       = length(google_sql_database_instance.main) > 0 ? google_sql_database_instance.main[0].private_ip_address : null
}

output "effective_db_host" {
  description = "Actual DB host string rendered into the VM's docker-compose.yml. Equal to cloud_sql_private_ip when managed, else var.db_host. Useful for debugging 'n8n can't reach the DB' incidents: if this output is empty the lifecycle.precondition on google_compute_instance_template.tpl (main.tf) will have failed plan already."
  value       = local.effective_db_host
}

# Resilience & DR (Phase 4)
output "billing_budget_name" {
  description = "Resource name of the monthly spend cap billing budget. Null when var.billing_account_id is empty (budget opted out). Edit the thresholds / amount by changing var.monthly_budget_usd and re-applying."
  value       = length(google_billing_budget.monthly_cap) > 0 ? google_billing_budget.monthly_cap[0].name : null
}
output "artifact_registry_repo" {
  description = "Artifact Registry repository for Docker images"
  value       = google_artifact_registry_repository.docker.id
}

output "persistent_data_disk" {
  description = "The persistent data disk used for Postgres"
  value       = google_compute_disk.data.id
}
