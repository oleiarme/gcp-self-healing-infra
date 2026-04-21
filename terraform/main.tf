terraform {
  required_version = ">= 1.0"

  # Backend настраивается через -backend-config=backend.conf
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_project_service" "required" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com"
  ])

  service = each.key
}

resource "google_service_account" "vm_sa" {
  account_id   = "n8n-app-sa"
  display_name = "n8n VM Service Account"
}

# ==========================================
# 1. SECRETS MANAGEMENT
# ==========================================

# 1.1 DB Password
resource "google_secret_manager_secret" "db_password" {
  secret_id = "n8n-db-secret"
  replication {
    user_managed {
      replicas { location = "us-central1" }
    }
  }
}

resource "google_secret_manager_secret_version" "db_password_v" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

resource "google_secret_manager_secret_iam_member" "access" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm_sa.email}"
}

# 1.2 n8n Encryption Key
resource "google_secret_manager_secret" "n8n_key" {
  secret_id = "n8n-encryption-key"
  replication {
    user_managed {
      replicas { location = "us-central1" }
    }
  }
}

resource "google_secret_manager_secret_version" "n8n_key_v" {
  secret      = google_secret_manager_secret.n8n_key.id
  secret_data = var.n8n_encryption_key
}

resource "google_secret_manager_secret_iam_member" "n8n_key_access" {
  secret_id = google_secret_manager_secret.n8n_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm_sa.email}"
}

# 1.3 Cloudflare Tunnel Token
resource "google_secret_manager_secret" "cf_token" {
  secret_id = "n8n-cf-token"
  replication {
    user_managed {
      replicas { location = "us-central1" }
    }
  }
}

resource "google_secret_manager_secret_version" "cf_token_v" {
  secret      = google_secret_manager_secret.cf_token.id
  secret_data = var.CF_TUNNEL_TOKEN
}

resource "google_secret_manager_secret_iam_member" "cf_token_access" {
  secret_id = google_secret_manager_secret.cf_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm_sa.email}"
}

# ==========================================
# 2. COMPUTE RESOURCES
# ==========================================

resource "google_compute_health_check" "hc" {
  name = "n8n-health-check"

  http_health_check {
    port         = 5678
    request_path = "/healthz"
  }

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 5
}

resource "google_compute_instance_template" "tpl" {
  depends_on = [
    google_secret_manager_secret.db_password,
    google_secret_manager_secret.n8n_key,
    google_secret_manager_secret.cf_token
  ]
  name_prefix  = "n8n-"
  machine_type = "e2-micro"

  disk {
    source_image = "ubuntu-os-cloud/ubuntu-2204-lts"
    disk_size_gb = 30
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network = "default"

    access_config {
      network_tier = "STANDARD"
    }
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = templatefile("${path.module}/../scripts/startup.sh", {
      db_host               = var.db_host
      db_user               = var.db_user
      DB_SECRET_NAME        = google_secret_manager_secret.db_password.secret_id
      N8N_KEY_SECRET_NAME   = google_secret_manager_secret.n8n_key.secret_id
      CF_TUNNEL_SECRET_NAME = google_secret_manager_secret.cf_token.secret_id
      db_name               = "postgres"
      db_port               = "5432"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_instance_group_manager" "mig" {
  name               = "n8n-mig"
  base_instance_name = "n8n"
  zone               = var.zone
  target_size        = 1

  version {
    instance_template = google_compute_instance_template.tpl.id
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.hc.id
    initial_delay_sec = 1300 # Оптимизировано с 1500
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1
    replacement_method    = "RECREATE"
  }
}


