resource "google_monitoring_dashboard" "n8n_slo" {
  project = var.project_id
  dashboard_json = templatefile("${path.module}/dashboards/n8n-slo.json.tftpl", {
    uptime_check_id = google_monitoring_uptime_check_config.n8n.uptime_check_id
    host            = var.n8n_public_host
    log_metric      = google_logging_metric.n8n_startup_critical.name
    mig_name        = google_compute_instance_group_manager.mig.name
    zone            = var.zone
  })
}
