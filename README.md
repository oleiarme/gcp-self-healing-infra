# GCP Self-Healing Infrastructure for n8n

[![terraform-deploy](https://github.com/oleiarme/gcp-self-healing-infra/actions/workflows/deploy.yml/badge.svg)](https://github.com/oleiarme/gcp-self-healing-infra/actions/workflows/deploy.yml)
[![terraform-validate](https://github.com/oleiarme/gcp-self-healing-infra/actions/workflows/terraform.yml/badge.svg)](https://github.com/oleiarme/gcp-self-healing-infra/actions/workflows/terraform.yml)

Production-grade self-healing infrastructure on **GCP Free Tier** that automatically recovers n8n if it crashes — using Managed Instance Group (MIG), persistent stateful storage, Artifact Registry image caching, and Cloudflare Tunnel.

## Architecture

![GCP Self-Healing Infra Architecture](gcp_self_healing_infra_architecture.png)

```
┌──────────────────────────────────────────────────────────────┐
│                    GitHub Actions CI/CD                       │
│         Workload Identity Federation (keyless auth)          │
│                                                              │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │  deploy.yml │  │ app-deploy   │  │  terraform.yml     │  │
│  │ (infra+MIG) │  │ (in-place,   │  │ (validate+lint     │  │
│  │             │  │  5s downtime)│  │  +security scan)   │  │
│  └──────┬──────┘  └──────┬───────┘  └────────────────────┘  │
│         │ terraform apply │ SSH (IAP)                        │
└─────────┼─────────────────┼────────────────────────────────-─┘
          ▼                 ▼
┌──────────────────────────────────────────────────────────────┐
│                   GCP us-central1                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │         Regional Managed Instance Group (MIG)        │    │
│  │           (auto-heals across us-central1-a/b/f)      │    │
│  │                                                      │    │
│  │  ┌───────────────────────────────────────────────┐   │    │
│  │  │            e2-micro VM (Free Tier)            │   │    │
│  │  │                                               │   │    │
│  │  │  ┌──────────────┐   ┌──────────────────────┐  │   │    │
│  │  │  │     n8n      │   │     cloudflared       │  │   │    │
│  │  │  │   :5678      │◄──│     Tunnel            │  │   │    │
│  │  │  └──────────────┘   └──────────────────────┘  │   │    │
│  │  │  ┌──────────────┐   ┌──────────────────────┐  │   │    │
│  │  │  │  PostgreSQL  │   │   Health Server      │  │   │    │
│  │  │  │  (Docker)    │   │   :8080 /healthz     │  │   │    │
│  │  │  └──────────────┘   └──────────────────────┘  │   │    │
│  │  └───────────────────────────────────────────────┘   │    │
│  │                         │                            │    │
│  │              Stateful Disk (pd-standard)             │    │
│  │              /mnt/data/postgres  ← never deleted     │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌─────────────────────┐  ┌──────────────────────────────┐   │
│  │   Artifact Registry │  │      Secret Manager          │   │
│  │   n8n-docker (AR)   │  │  db-password / n8n-key /     │   │
│  │   (image cache)     │  │  cf-token                    │   │
│  └─────────────────────┘  └──────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
                              │
                    Cloudflare Edge (HTTPS)
                              │
                        Your Browser
```

## Key Features

- **Self-healing**: MIG auto-replaces unhealthy VMs; no manual intervention needed
- **Stateful data**: Postgres data on a persistent disk (`pd-standard`) that **survives VM recreation**
- **Fast app updates**: In-place deploy via SSH/IAP — update n8n in **5 seconds**, not 15 minutes
- **Image caching**: Artifact Registry mirrors Docker Hub, bypassing rate limits and accelerating cold starts
- **100% Free Tier**: e2-micro VM + 30 GB total storage (20 GB boot + 10 GB data) in `us-central1`
- **Keyless CI/CD**: Workload Identity Federation — no JSON service account keys stored anywhere
- **Defense in depth**: `tflint` + `tfsec` + `Checkov` + `shellcheck` + `trivy` on every PR

## Why This Matters (Business Value)

    While this project is technically dense, here is the bottom line for decision-makers:

    - 💰 Zero Cost: Runs entirely on GCP Free Tier ($0/month) vs. $50–200/month for managed n8n or n8n.cloud hosting. Ideal for startups and personal automation.
    - 🛡️ Reliability by Design: 99.5% SLO (max 3.6h downtime/month). The infrastructure heals itself — no 3am pages for crashed VMs.
    - 🔒 Enterprise-Grade Security: Keyless CI/CD (Workload Identity), least-privilege IAM, and secrets never stored in plaintext. Complies with strict audit requirements.
    - ⚡ Fast Recovery: <17 min cold-start recovery, <7 min warm replacment. We measure it, we drill it, we prove it.
    - 📉 Risk Reduction: Prevents "zonal outage" scenarios and offers Point-in-Time Recovery (PITR) for data, turning disasters into minor blips.

## How Self-Healing Works

1. **GCP Health Check** polls `http://VM:8080/` every **10s** (timeout 10s). 2 successes → healthy; 7 consecutive failures → unhealthy.
2. **Bootstrap grace window**: `initial_delay_sec = 1800s` (30 min) prevents MIG from replacing a VM that is still booting. The health server returns 200 during this window regardless of container state.
3. **MIG auto-healing**: Once unhealthy status is confirmed, MIG recreates the VM. `replacement_method = RECREATE` ensures the stateful data disk is detached before the new VM claims it.
4. **Startup sequence** (`startup.sh`):
   - Fetch secrets from Secret Manager
   - Mount persistent disk (`/dev/disk/by-id/google-n8n-data` → `/mnt/data/postgres`)
   - Format disk on first boot only (idempotent thereafter)
   - Try Artifact Registry for images, fall back to Docker Hub
   - Launch Postgres, n8n, cloudflared via Docker Compose
   - Start health server on `:8080`
5. **Recovery budget**: Cold start ≤ 30 min. Warm app-only update: **5 seconds**.

## Stack

| Component | Technology | Why |
|---|---|---|
| IaC | Terraform | Reproducible, auditable infra |
| Compute | GCP e2-micro | Always Free in us-central1 |
| Self-healing | Regional MIG + Health Check | Auto-replace crashed VM across zones |
| Data persistence | pd-standard stateful disk | Postgres data survives VM recreation |
| Image cache | Artifact Registry (`n8n-docker`) | Bypass Docker Hub rate limits |
| Workflow engine | n8n | Open-source automation platform |
| Database | PostgreSQL (Docker) | On-VM, data on persistent disk |
| Secrets | GCP Secret Manager | No plaintext credentials anywhere |
| Tunnel | Cloudflare Tunnel | HTTPS without open inbound ports |
| CI/CD | GitHub Actions + WIF | Keyless authentication |
| Alerting | Cloud Monitoring + Telegram | SLO burn-rate + startup alerts |

## Deployment Modes (Shearing Layers)

This repo implements the **Shearing Layers** principle: infrastructure changes rarely, application changes often.

| Scenario | Workflow | Downtime | When to use |
|---|---|---|---|
| n8n version bump, config change | `app-deploy.yml` | **2-5 seconds** | Routine updates |
| Disk size, network, IAM, MIG config | `deploy.yml` | 15-30 min (VM recreate) | Infra changes |
| Terraform format/lint/security | `terraform.yml` | None (read-only) | Every PR |

### In-Place Deploy (app-deploy.yml)

To update n8n without recreating the VM:

1. Go to **Actions → App Deploy (In-Place) → Run workflow**
2. Optionally enter a new `n8n_image` ref (e.g. `docker.n8n.io/n8nio/n8n:1.1.0`)
3. Click **Run workflow**

The workflow will:
- Mirror the new image to Artifact Registry
- SSH into the running VM via IAP tunnel
- Pull the new image and restart only the `n8n` container
- Verify health in 30 seconds

> ⚠️ **Important:** After validating the new version in production, update `var.n8n_image` and `var.n8n_image_tag` in `terraform/variables.tf` and push. Otherwise, the next VM recreation will revert to the old version.

## Free Tier Compliance

| Resource | Limit | Our config |
|---|---|---|
| VM | 1× e2-micro in `us-west1`, `us-central1`, or `us-east1` | ✅ e2-micro in `us-central1` |
| Disk | 30 GB standard persistent disk | ✅ 20 GB boot + 10 GB data = **30 GB** |
| Network | 1 GB egress/month to same region | ✅ STANDARD tier, internal traffic |
| Artifact Registry | 0.5 GB storage | ✅ ~400 MB (2 images) |

> ⚠️ Always keep `target_size = 1` and `max_surge_fixed = 0` in the MIG config. Running two e2-micro instances simultaneously exits Free Tier.

Performance Optimization Case Study

    Problem: 40-minute cold starts
    Initial setup used Supabase (hosted in a different region) with Ops Agent installed.
    This caused:
    - Cross-region latency for every DB connection
    - CPU 99% utilization during startup
    - MTTR: ~40 minutes (unacceptable for 99.5% SLO)

    Solution: Cloud SQL in-region + optimization
    1. Migrated to Cloud SQL PostgreSQL in the same us-central1 region
    2. Removed Ops Agent (exceeded e2-micro IO budget)
    3. Result: 3x faster recovery — MTTR dropped to ~18 minutes

    Roadmap: Golden Image
    Next optimization: create a golden disk with pre-loaded Docker images.
    - Target MTTR: 7-9 minutes (2x faster than current)
    - Trade-off: Slight increase in disk usage (still within Free Tier 30GB)
    - Status: Pending (see initial_delay_sec discussion in Runbook §2)

## Prerequisites

- GCP project with billing enabled (for API access; cost stays $0 within Free Tier)
- GCS bucket for Terraform state (can be created with `terraform/bootstrap/`)
- Cloudflare Tunnel token (free account at cloudflare.com)
- GitHub repository secrets and variables configured (see below)

## Quick Start

### 1. Bootstrap Terraform state bucket

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="project_id=YOUR_PROJECT_ID"
```

### 2. Configure backend

```bash
cd ../  # back to terraform/
cp backend.conf.example backend.conf
# Edit backend.conf with your bucket name
```

### 3. Configure variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 4. Deploy locally

```bash
terraform init -backend-config=backend.conf
terraform plan
terraform apply
```

### 5. Deploy via GitHub Actions

Configure **Settings → Secrets and variables → Actions**:

**Secrets:**
| Name | Required | Description |
|---|---|---|
| `WIF_PROVIDER` | ✅ | Workload Identity Federation provider URI |
| `WIF_SA` | ✅ | Service account email for WIF |
| `TF_BACKEND_BUCKET` | ✅ | GCS bucket name for Terraform state |
| `TF_VAR_CF_TUNNEL_TOKEN` | ✅ | Cloudflare Tunnel token |
| `TF_VAR_db_password` | ✅ | PostgreSQL password |
| `TF_VAR_n8n_encryption_key` | ✅ | n8n encryption key (32+ random chars) |
| `GCP_BILLING_ACCOUNT_ID` | optional | Enables `$5/month` billing budget alert |
| `SLACK_BOT_TOKEN` | optional | Slack `xoxb-…` token for alert routing |
| `TELEGRAM_BOT_TOKEN` | optional | Telegram bot token for deploy notifications |

**Variables (non-secret):**
| Name | Required | Description |
|---|---|---|
| `TF_VAR_project_id` | ✅ | GCP project ID |
| `TF_VAR_db_user` | ✅ | PostgreSQL username |
| `TF_VAR_n8n_public_host` | ✅ | Public FQDN for uptime checks (e.g. `n8n.example.com`) |
| `TF_VAR_oncall_email` | ✅ | Email for SLO burn-rate and startup alerts |
| `TF_VAR_region` | optional | GCP region (default: `us-central1`) |
| `TF_VAR_zone` | optional | GCP zone (default: `us-central1-a`) |
| `TF_VAR_slack_channel` | optional | Slack channel for alerts (e.g. `#n8n-ops`) |
| `BACKUP_BUCKET_NAME` | ✅ | GCS bucket for Postgres backups |
| `TELEGRAM_CHAT_ID` | optional | Telegram chat ID for notifications |

Push to `main` → CI/CD runs `deploy.yml`. The `terraform apply` step requires a human reviewer to approve via the `production` GitHub Environment.

## Security Posture

### Identity & Access (Least Privilege)

| Identity | Scope | IAM Bindings |
|---|---|---|
| `n8n-app-sa` (VM) | `cloud-platform` (required for Secret Manager) | `roles/logging.logWriter`, `roles/monitoring.metricWriter` (project), `roles/secretmanager.secretAccessor` per-secret |
| GitHub Actions deployer | WIF federated | Project editor — scoped to `main` branch of this repo only via attribute condition |

### Keyless Authentication (WIF)

No JSON keys. GitHub Actions mints a short-lived OIDC token, exchanged for GCP credentials via Workload Identity Federation. The WIF provider **must** be configured with an attribute condition:

```bash
gcloud iam workload-identity-pools providers update-oidc github \
  --workload-identity-pool=github-pool \
  --location=global \
  --attribute-condition='assertion.repository == "<YOUR_GH_OWNER>/gcp-self-healing-infra" && assertion.ref == "refs/heads/main"'
```

### Container Image Pinning

Both images are pinned by SHA256 digest in `terraform/variables.tf`. A re-tagged image cannot silently change what runs in production.

Digests are refreshed weekly by `.github/workflows/digest-refresh.yml` (Mondays 06:00 UTC) via `crane digest` → `terraform validate` → auto PR.

### Static Analysis in CI

| Check | Tool | Blocks PR? |
|---|---|---|
| `terraform fmt` | Terraform | ✅ |
| `terraform validate` | Terraform | ✅ |
| `tflint` | terraform-linters + GCP ruleset | ✅ (warnings+) |
| `tfsec` | aquasecurity/tfsec-action | ✅ (HIGH/CRITICAL) |
| `Checkov` | bridgecrewio/checkov-action | ✅ |
| `shellcheck` | shellcheck | ✅ |
| `trivy` (images) | aquasecurity/trivy-action | Advisory (non-blocking) |

### Data Protection

- Secrets stored in **Secret Manager** with `prevent_destroy = true`
- Postgres data disk has `prevent_destroy = true` — `terraform destroy` cannot wipe it
- `delete_rule = "NEVER"` on the MIG stateful disk policy — VM recreation never deletes data
- Disk formatted only on first boot; subsequent boots mount the existing filesystem

## SLO / SLI

| Metric | Target | How measured |
|---|---|---|
| **Availability** | 99.5% over 28d rolling | External uptime check on `https://<n8n_public_host>/healthz`, 6 probe locations, 60s period |
| **Recovery time (VM recreate)** | ≤ 30 min | `initial_delay_sec` (1800s) + HC detection + startup.sh |
| **Recovery time (in-place)** | ≤ 5 seconds | `docker compose up -d --no-deps n8n` |

**Error budget:** 3.6h downtime/month (0.5%).

### Burn-Rate Alerts

| Policy | Signal | Severity | Channels |
|---|---|---|---|
| `n8n SLO fast burn` | uptime good-fraction < 0.928 over 1h (14.4× burn) | **CRITICAL** | Email + Slack + Telegram |
| `n8n SLO slow burn` | uptime good-fraction < 0.97 over 6h (6× burn) | WARNING | Email + Slack |
| `n8n startup CRITICAL` | log-based metric `n8n/startup_critical` > 0 in 5m | WARNING | Email + Slack |
| `n8n log ingestion absent` | startup log silent for 24h | **CRITICAL** | Email + Slack |

## Resilience & DR

### Stateful Persistent Disk

Postgres data lives on `google-n8n-data` (pd-standard, `us-central1-a`). The MIG is configured with:
- `stateful_disk { device_name = "n8n-data", delete_rule = "NEVER" }`
- `replacement_method = "RECREATE"` — required for stateful workloads (disk can't attach to two VMs)
- `max_surge = 0`, `max_unavailable = 1` — ensures clean sequential replacement

### Zonal Failover

The Regional MIG can place the VM in any zone of `us-central1` (`a/b/f`). On a zonal incident, MIG recreates the VM in a surviving zone. **Note:** The persistent disk is zonal (`us-central1-a`). If zone `a` is unavailable, the VM relocates but cannot attach the disk until zone `a` recovers. For full zonal tolerance of data, upgrade to a multi-zone setup (out of Free Tier scope).

### Terraform State

GCS backend with **object versioning** and 90-day retention for the last 30 non-current versions. Every `terraform apply` produces a rollback-able snapshot.

## Observability

### Logging

`startup.sh` installs the Google Cloud Ops Agent with a **logging-only** config (no host metrics — they caused I/O saturation on e2-micro). Logs are shipped from `/var/log/startup.log` to Cloud Logging and power the `n8n/startup_critical` log-based metric.

### Dashboard

`google_monitoring_dashboard.n8n_slo` provides four tiles:
- Uptime good-fraction
- 1h / 6h burn rate with alert thresholds
- MIG instance count
- Startup CRITICAL events counter

### Telegram Notifications

A Cloud Function (`n8n-telegram-alert`) is triggered by Pub/Sub on deploy events and sends messages to your configured Telegram chat. Activated when `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are set.

## Operational Practices

| Document | Purpose |
|---|---|
| [Runbook.md](Runbook.md) | Incident response (MIG recreation, boot loops, secret rotation, DR) |
| [docs/slo-roadmap.md](docs/slo-roadmap.md) | Phase-by-phase feature roadmap |
| [docs/error-budget-policy.md](docs/error-budget-policy.md) | Release freeze triggers at 50/90/100% budget |
| [docs/oncall.md](docs/oncall.md) | Primary/backup roster, ACK/resolve SLAs |
| [docs/postmortems/TEMPLATE.md](docs/postmortems/TEMPLATE.md) | Google SRE Workbook post-mortem format |
| [docs/drills/](docs/drills/) | Chaos engineering drill schedule and pass criteria |

## Project Structure
 
```
.
├── .github/
│   ├── actions/
│   │   └── telegram-notify/        # Reusable Telegram notification action
│   └── workflows/
│       ├── deploy.yml              # Full infra deploy (Terraform apply)
│       ├── app-deploy.yml          # In-place app update via SSH/IAP (5s)
│       ├── terraform.yml           # PR validation (fmt/validate/lint/scan)
│       ├── digest-refresh.yml      # Weekly image digest auto-update
│       ├── schedule-vm-start.yml   # Morning VM start (cost optimization)
│       └── schedule-vm-stop.yml    # Night VM stop (22:00 UTC daily)
├── scripts/
│   └── startup.sh                  # VM bootstrap (disk mount, Docker, n8n)
├── terraform/
│   ├── main.tf                     # Core: MIG, disk, AR, network, IAM
│   ├── variables.tf                # All input variables
│   ├── outputs.tf                  # Outputs for debugging and alerting
│   ├── monitoring.tf               # Uptime checks, alerts, dashboards
│   ├── dashboards.tf               # Cloud Monitoring dashboard
│   ├── cloud_sql.tf                # Optional: Cloud SQL as code
│   ├── telegram.tf                 # Telegram notification Cloud Function
│   ├── bootstrap/                  # One-shot: create GCS state bucket
│   ├── functions/                  # Cloud Function source (Telegram alert)
│   ├── dashboards/                 # Dashboard JSON template
│   └── backend.conf.example        # Backend config template
├── docs/
│   ├── slo-roadmap.md
│   ├── error-budget-policy.md
│   ├── oncall.md
│   ├── drills/
│   └── postmortems/
├── Runbook.md                      # Incident playbook
├── renovate.json                   # Renovate bot config
└── README.md
```

## Outputs

After `terraform apply`:

| Output | Use case |
|---|---|
| `mig_name` | Identify MIG in GCP Console |
| `mig_distribution_zones` | Confirm zone distribution |
| `persistent_data_disk` | Verify disk resource exists |
| `artifact_registry_repo` | Check AR repository |
| `health_check_name` | Set up Cloud Monitoring alerting |
| `vm_service_account_email` | Filter logs by service account |
| `secret_names` | Quick reference for secret rotation |
| `deployment_timestamp` | Correlate changes across logs |

## Runbook Quick Reference

| Scenario | Section |
|---|---|
| VM was auto-recreated by MIG | [§1](Runbook.md#1-mig-recreated-vm-health-check-failed) |
| VM stuck in boot loop / startup timeout | [§2](Runbook.md#2-startup-timeout--boot-loop) |
| Rotate DB password / n8n key / CF token | [§3](Runbook.md#3-secret-rotation) |
| Manual Terraform redeploy | [§4](Runbook.md#4-mig-update--terraform-redeploy) |
| Postgres backup / restore / zonal failover | [§5](Runbook.md#5-backup--dr) |
| Escalation matrix & post-mortem trigger | [§6](Runbook.md#6-escalation--on-call) |

## VM Schedule

To reduce Free Tier egress and IP costs when n8n is not actively used, the VM is stopped every night at **22:00 UTC** and started every morning at **07:00 UTC** (Mon–Fri) via scheduled GitHub Actions workflows.

Disable by setting the GitHub variable 
`VM_SCHEDULE_ENABLED=false`.

## License

MIT — see [LICENSE](LICENSE).

## Skills Demonstrated (for Recruiters)
    SRE: SLO/SLI, error budgets, burn-rate alerting, post-mortem culture, chaos drills
    Cloud: GCP (MIG, Cloud SQL, Secret Manager, IAM, Monitoring)
    IaC: Terraform (modules, remote state, import, prevent_destroy)
    CI/CD: GitHub Actions, WIF, branch protection, automated digest refresh
    Security: Least privilege, secret rotation, static analysis (tfsec/checkov/trivy)
    Observability: Custom dashboards, multi-window alerts, log-based metrics