# ==========================================
# Morning VM start via Cloud Scheduler (08:30 Europe/Lisbon)
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
# 08:30 leaves room for a cold start (14-18 min, e.g. a template update is
# pending) before the 09:05 end of the nightly alert snooze.
#
# The job only checks the HTTP answer of the PATCH (an async operation). If
# the MIG then fails to start the VM (quota, zone stockout), the job still
# shows success; the uptime alerts after 09:05 are what report it.
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
  display_name = "n8n VM schedule (Cloud Scheduler + Workflows)"
  description  = "Cloud Scheduler / Workflows: start the n8n VM at 08:30 and stop it at 20:00 Lisbon (MIG standby pool)."
}

# Needs compute.instanceGroupManagers.update on the MIG. There is no
# resource-level IAM for regional MIGs, and a custom role would need
# iam.roles.create on the deploy SA, so the narrowest predefined role is used.
resource "google_project_iam_member" "vm_scheduler_instance_admin" {
  # checkov:skip=CKV_GCP_42: needs compute.instanceGroupManagers.update; no resource-level IAM for regional MIGs, custom roles not allowed for the deploy SA
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.vm_scheduler.email}"
}

resource "google_cloud_scheduler_job" "vm_morning_start" {
  name        = "n8n-vm-morning-start"
  description = "Start the stopped n8n VM from the MIG standby pool before 09:00 Lisbon."
  region      = var.region
  # 08:30: a standby start takes ~4 min to n8n /healthz 200.
  schedule         = "30 8 * * *"
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

# ==========================================
# Nightly VM stop via Cloud Scheduler + Workflows (20:00 Europe/Lisbon)
# ==========================================
# Unlike the start, the stop is not a single PATCH: it must never stop a VM
# in the middle of its COS first boot (post-mortem 2026-11-26) and it has to
# create the nightly alert snoozes. The workflow (workflows/vm_nightly_stop.yaml)
# waits until the MIG is idle and the VM is >= 40 min old (up to 2 h),
# creates the snoozes (end 09:05 / 15:05 Lisbon), re-checks, then
# stopInstances. The GitHub "Stop VM" workflow stays as a fallback.
#
# Cost: 2nd Cloud Scheduler job (3 free per billing account); the workflow
# uses ~50-70 internal steps per run, ~2,000 a month (5,000 free per month).

resource "google_project_service" "workflows" {
  project            = var.project_id
  service            = "workflows.googleapis.com"
  disable_on_destroy = false
}

# The same SA runs the workflow (stop VM, create snoozes, write its logs)
# and lets Cloud Scheduler start workflow executions.
resource "google_project_iam_member" "vm_scheduler_roles" {
  for_each = toset([
    "roles/workflows.invoker",
    "roles/monitoring.snoozeEditor",
    "roles/monitoring.alertPolicyViewer",
    "roles/logging.logWriter",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.vm_scheduler.email}"
}

resource "google_workflows_workflow" "vm_nightly_stop" {
  name            = "n8n-vm-nightly-stop"
  region          = var.region
  description     = "Stop the n8n VM into the MIG standby pool: wait for idle MIG and VM >= 40 min old, create nightly alert snoozes, stopInstances."
  service_account = google_service_account.vm_scheduler.id
  call_log_level  = "LOG_ERRORS_ONLY"
  source_contents = file("${path.module}/workflows/vm_nightly_stop.yaml")

  depends_on = [
    google_project_service.workflows,
    google_project_iam_member.vm_scheduler_roles,
  ]
}

resource "google_cloud_scheduler_job" "vm_nightly_stop" {
  name             = "n8n-vm-nightly-stop"
  description      = "Run the n8n-vm-nightly-stop workflow at 20:00 Lisbon."
  region           = var.region
  schedule         = "0 20 * * *"
  time_zone        = "Europe/Lisbon"
  attempt_deadline = "60s"

  retry_config {
    retry_count          = 3
    min_backoff_duration = "60s"
    max_backoff_duration = "300s"
  }

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.vm_nightly_stop.id}/executions"
    body        = base64encode(jsonencode({ argument = jsonencode({}) }))
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
    google_project_iam_member.vm_scheduler_roles,
  ]
}
