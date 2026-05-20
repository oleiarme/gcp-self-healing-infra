terraform {
  required_version = ">= 1.0"

  # Backend настраивается через -backend-config=backend.conf
  # Placeholder bucket — перезаписывается -backend-config="bucket=..." в CI
  backend "gcs" {
    bucket = "tf-state-placeholder"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
