resource "google_compute_instance_template" "tpl" {
  name_prefix  = "n8n-"
  machine_type = "e2-micro" # ВОЗВРАЩЕНО: Обязательный параметр

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
    # ИСправлено: Широкий scope нужен для API, безопасность обеспечивается IAM ролью SA
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
    create_before_destroy = false
  }
}
