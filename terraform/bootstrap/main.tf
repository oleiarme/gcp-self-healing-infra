# ==========================================
# TERRAFORM STATE BUCKET BOOTSTRAP
# ==========================================
# Chicken-and-egg: the GCS bucket that stores the main stack's state
# cannot be created by that same stack (it's declared as the backend
# before any resource can be planned). This bootstrap module exists
# once, runs with a local state file, and produces exactly one
# resource: the bucket itself, with the durability features the
# main stack relies on — versioning and a lifecycle rule to keep
# ~90 days of deleted state revisions.
#
# ---
# ONE-SHOT USAGE
# ---
#
#   cd terraform/bootstrap
#   terraform init                    # local backend, no backend config
#   terraform plan -var project_id=YOUR-PROJECT -var bucket_name=YOUR-BUCKET
#   terraform apply -var project_id=YOUR-PROJECT -var bucket_name=YOUR-BUCKET
#
# This writes terraform/bootstrap/terraform.tfstate (local), which is
# harmless — deleting it does not delete the bucket, only Terraform's
# knowledge of it. The main stack then uses the bucket as its remote
# backend via -backend-config="bucket=YOUR-BUCKET".
#
# ---
# WHAT THIS MODULE IS NOT
# ---
#
# Not a "bootstrap everything" module. It intentionally does not:
#   * create the GCP project
#   * enable project APIs
#   * set up Workload Identity Federation
#   * create the CI/CD service account
#
# Those are either provisioned elsewhere (WIF / SA) or assumed to
# already exist (project). Keeping the module tiny avoids the trap
# where the bootstrap itself becomes something that needs its own
# bootstrap.
#
# Full procedure including rollback: Runbook §5.2 State bucket restore.

terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Intentionally local state. Do not flip this to a gcs backend —
  # the whole point is to bootstrap a bucket without a bucket.
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  description = "GCP project ID that will own the Terraform state bucket."
  type        = string
}

variable "region" {
  description = "Bucket location. Use the same region as the main stack so state reads/writes stay regional."
  type        = string
  default     = "us-central1"
}

variable "bucket_name" {
  description = "Globally-unique GCS bucket name. Convention: '<project_id>-tfstate'. Must be DNS-safe (lowercase, digits, hyphens, 3-63 chars)."
  type        = string
}

variable "versioning_noncurrent_retention_days" {
  description = "Number of days to keep non-current (previous) object versions. Trades state-rollback depth against storage cost; 90d covers a full quarterly audit window."
  type        = number
  default     = 90
}

variable "versioning_noncurrent_version_cap" {
  description = "Maximum number of non-current versions to retain per object. Caps storage even if a write-heavy burst produces 30+ revisions inside the retention window. Must match the claim in README §Terraform state rollback (currently 30)."
  type        = number
  default     = 30
}

resource "google_storage_bucket" "tfstate" {
  # checkov:skip=CKV_GCP_62:Access logs for the state bucket would themselves need a storage bucket, recursing the bootstrap problem. Cloud Audit Logs for GCS admin activity (enabled by default, not per-bucket) already answers the audit question that matters: who created/deleted/overwrote state objects. Per-object read logging would be pure noise, since every `terraform plan` reads state.
  name          = var.bucket_name
  project       = var.project_id
  location      = var.region
  force_destroy = false

  # Primary reason this bootstrap exists: every `terraform apply`
  # overwrites state. Without versioning a corrupt plan can wipe
  # every tracked resource from Terraform's perspective with no
  # undo. With versioning enabled, `gsutil` can roll back to any
  # previous generation.
  versioning {
    enabled = true
  }

  # Age out non-current versions so the bucket doesn't grow unbounded.
  # Two rules, OR'd by GCS (a version matching EITHER is deleted):
  #
  #   1. Cap the count at `versioning_noncurrent_version_cap` (default
  #      30). Prevents a pathological write-heavy burst from ballooning
  #      storage even if no version is older than the age limit.
  #   2. Cap the age at `versioning_noncurrent_retention_days` (default
  #      90). `num_newer_versions = 1` is the "pin to non-current only"
  #      idiom — the live version always counts as newer, so the
  #      condition skips the current object and acts only on superseded
  #      revisions.
  #
  # Live (current) objects are never affected by either rule.
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions = var.versioning_noncurrent_version_cap
    }
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions = 1
      age                = var.versioning_noncurrent_retention_days
    }
  }

  uniform_bucket_level_access = true

  # Publicly-inaccessible by default (no "allUsers" / "allAuthenticatedUsers"
  # grants here). State contains secret material; any IAM binding needs
  # to be explicit.
  public_access_prevention = "enforced"

  # Fail loud if someone tries to destroy the bucket via Terraform.
  # Cost of a false positive (need to type two extra commands during
  # a genuine teardown) is nothing compared to the blast radius of
  # an accidental apply dropping the only copy of production state.
  lifecycle {
    prevent_destroy = true
  }
}

output "state_bucket_name" {
  description = "Name of the bucket the main stack should use in its backend config (bucket = <this value>)."
  value       = google_storage_bucket.tfstate.name
}

output "state_bucket_url" {
  description = "gs:// URL of the bucket, useful for manual `gsutil` operations (version list, rollback)."
  value       = google_storage_bucket.tfstate.url
}
