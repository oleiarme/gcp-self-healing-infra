resource "google_monitoring_dashboard" "n8n_slo" {
  project = var.project_id
  dashboard_json = templatefile("${path.module}/dashboards/n8n-slo.json.tftpl", {
    uptime_check_id = google_monitoring_uptime_check_config.n8n.uptime_check_id
    host            = var.n8n_public_host
    log_metric      = google_logging_metric.n8n_startup_critical.name
    # MIG is regional since Phase 4. Cloud Monitoring exposes both zonal
    # and regional MIGs under resource.type="instance_group" with the
    # same metadata.system_labels.instance_group_name, so the dashboard
    # filter works unchanged.
    mig_name = google_compute_region_instance_group_manager.mig.name
    zone     = var.zone # kept for template back-compat; unused in the filter itself
  })
}
