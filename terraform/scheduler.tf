# ==========================================
# Morning VM start via Cloud Scheduler
# ==========================================
# GitHub Actions schedules are best-effort: for this repo the hourly
# "Start VM" cron fired only ~2 times a day, so the morning start landed at
# 13:00-18:00 Lisbon instead of 09:00. Cloud Scheduler fires on the minute
# in a real time zone.
#
# The job PATCHes the MIG with targetSize=1 and targetStoppedSize=0 in ONE
# request. With standby_policy MANUAL a plain resize would create a NEW VM;
# changing both sizes together makes the MIG start the stopped VM from the
# standby pool instead (verified live 2026-11-26: same instance n8n-1szm
# started, no new VM). If the MIG has no stopped VM, the same request
# creates one (cold start) — same outcome as the old resize fallback.
#
# The GitHub "Start VM" workflow stays as a fallback: when it runs later
# and finds the VM RUNNING, it skips.
#
# Cost: 1 job; Cloud Scheduler gives 3 jobs per billing account free.
# target_size / target_stopped_size are in the MIG's ignore_changes, so a
# terraform apply does not fight this job.

resource "google_project_service" "cloudscheduler" {
  project            = var.project_id
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "vm_scheduler" {
  account_id   = "n8n-vm-scheduler"
  display_name = "n8n VM morning start (Cloud Scheduler)"
  description  = "Used only by Cloud Scheduler to start the stopped n8n VM from the MIG standby pool."
}

# Needs compute.instanceGroupManagers.update on the MIG. There is no
# resource-level IAM for regional MIGs, and a custom role would need
# iam.roles.create on the deploy SA, so the narrowest predefined role is used.
resource "google_project_iam_member" "vm_scheduler_instance_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.vm_scheduler.email}"
}

resource "google_cloud_scheduler_job" "vm_morning_start" {
  name        = "n8n-vm-morning-start"
  description = "Start the stopped n8n VM from the MIG standby pool before 09:00 Lisbon."
  region      = var.region
  # 08:45: a standby start takes ~4 min to n8n /healthz 200.
  schedule         = "45 8 * * *"
  time_zone        = "Europe/Lisbon"
  attempt_deadline = "60s"

  retry_config {
    retry_count          = 3
    min_backoff_duration = "60s"
    max_backoff_duration = "300s"
  }

  http_target {
    http_method = "PATCH"
    uri         = "https://compute.googleapis.com/compute/v1/projects/${var.project_id}/regions/${var.region}/instanceGroupManagers/${google_compute_region_instance_group_manager.mig.name}"
    body        = base64encode(jsonencode({ targetSize = 1, targetStoppedSize = 0 }))
    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.vm_scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_project_iam_member.vm_scheduler_instance_admin,
  ]
}
