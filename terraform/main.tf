terraform {
  required_version = ">= 1.0"

  # Это магическая кнопка, которая лечит ошибку 409
  backend "gcs" {
}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_service_account" "vm_sa" {
  account_id = "n8n-vm-sa"
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "db-password"
  replication {
    user_managed {
      replicas {
        location = "us-central1"
      }
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

resource "google_compute_health_check" "hc" {
  name = "n8n-health-check"

  http_health_check {
    port         = 5678
    request_path = "/healthz"
  }
}

resource "google_compute_instance_template" "tpl" {
  depends_on   = [null_resource.free_tier_enforcer]
  name_prefix  = "n8n-"
  machine_type = "e2-micro"

  disk {
    source_image = "ubuntu-os-cloud/ubuntu-2204-lts"
    disk_size_gb = 30
    auto_delete = true
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
      db_host            = var.db_host
      db_user            = var.db_user
      DB_PASSWORD        = var.db_password
      n8n_encryption_key = var.n8n_encryption_key
      cf_tunnel_token    = var.CF_TUNNEL_TOKEN
      db_name            = "postgres"
      db_port            = "5432"
    })
  }

  lifecycle {
    create_before_destroy = false
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
    initial_delay_sec = 1500
  }

    update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1  # Сначала убить старую, потом создать новую
    replacement_method    = "RECREATE"
  }
}

resource "null_resource" "free_tier_enforcer" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
      set -e
      ZONE="us-central1-a"

      echo "🛡 Running Hardened Free Tier Check..."
      
      # 1. Сначала чистим диски, которые реально ни к кому не привязаны
      ORPHAN_DISKS=$(gcloud compute disks list --filter="zone:($ZONE) AND -users:*" --format="value(name)")
      for disk in $ORPHAN_DISKS; do
        echo "🧹 Deleting truly orphaned disk: $disk"
        gcloud compute disks delete "$disk" --zone="$ZONE" --quiet
      done

      # 2. Считаем остаток
      DISK_COUNT=$(gcloud compute disks list --filter="zone:($ZONE)" --format="value(name)" | wc -l)
      VM_COUNT=$(gcloud compute instances list --filter="status=RUNNING AND zone:($ZONE)" --format="value(name)" | wc -l)

      echo "📊 Stats after cleanup: $VM_COUNT VMs, $DISK_COUNT Disks"

      # 3. Финальный предохранитель
      if [ "$DISK_COUNT" -gt 1 ]; then
        echo "⚠️ WARNING: Multiple disks detected ($DISK_COUNT)."
        # Если ВМ 0, а дисков > 0 — значит это зависшие загрузочные диски старых машин
        if [ "$VM_COUNT" -eq 0 ]; then
          echo "🧨 Emergency cleaning of stuck boot disks..."
          gcloud compute disks list --filter="zone:($ZONE)" --format="value(name)" | xargs -I {} gcloud compute disks delete {} --zone="$ZONE" --quiet
        else
          echo "❌ Critical Error: Too many resources for Free Tier. Manual intervention required."
          exit 1
        fi
      fi
    EOT
  }
}
