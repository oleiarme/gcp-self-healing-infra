# GCP Self-Healing Infrastructure for n8n

[![terraform-deploy](https://github.com/oleiarme/gcp-self-healing-infra/actions/workflows/deploy.yml/badge.svg)](https://github.com/oleiarme/gcp-self-healing-infra/actions/workflows/deploy.yml)

Production-grade self-healing infrastructure on **GCP Free Tier** that automatically recovers n8n if it crashes — using Managed Instance Group (MIG), health checks, and Cloudflare Tunnel.

## Architecture
![GCP Self-Healing Infra Architecture](gcp_self_healing_infra_architecture.png)
```
┌──────────────────────────────────────────────────────────┐
│                    GitHub Actions CI/CD                   │
│              (Workload Identity Federation)               │
└──────────────────────┬───────────────────────────────────┘
                       │ terraform apply
                       ▼
┌──────────────────────────────────────────────────────────┐
│                   GCP us-central1-a                       │
│                                                           │
│  ┌───────────────────────────────────────────────────┐   │
│  │            Managed Instance Group (MIG)           │   │
│  │                                                   │   │
│  │  ┌─────────────────────────────────────────────┐  │   │
│  │  │           e2-micro VM (Free Tier)           │  │   │
│  │  │                                             │  │   │
│  │  │  ┌─────────────┐   ┌──────────────────┐   │  │   │
│  │  │  │    n8n      │   │   cloudflared    │   │  │   │
│  │  │  │   :5678     │◄──│   Tunnel         │   │  │   │
│  │  │  └─────────────┘   └──────────────────┘   │  │   │
│  │  │         │                    │              │  │   │
│  │  └─────────┼────────────────────┼─────────────┘  │   │
│  │            │                    │                 │   │
│  │   Health Check /healthz    Cloudflare Edge        │   │
│  │   (auto-restart on fail)   (HTTPS, no open IP)    │   │
│  └───────────────────────────────────────────────────┘   │
│                                                           │
│  ┌──────────────┐   ┌──────────────────┐                 │
│  │  Cloud SQL   │   │ Secret Manager   │                 │
│  │  PostgreSQL  │   │  db-password     │                 │
│  └──────────────┘   └──────────────────┘                 │
└──────────────────────────────────────────────────────────┘
```

## How Self-Healing Works

1. **In-cluster liveness** — GCP HTTP health check polls `/healthz` on the
   VM every **10s** (timeout 5s). 2 successes → healthy, 5 failures →
   unhealthy (~50s detection window).
2. **Docker container healthcheck** — the `n8n` container self-reports
   health every 10s after a **420s** `start_period` grace window
   (Docker-level, mirrors the GCP interval so there is no stale-health
   window where GCP reads healthy while n8n is already dead).
3. **MIG auto-healing** — unhealthy status triggers VM replacement.
   `initial_delay_sec = 600s` (> Docker `start_period` + 3 min safety)
   lets `startup.sh` reach `/healthz` OK before any replacement timer
   starts, preventing cold-boot loops on e2-micro.
4. **New VM runs `startup.sh`** → apt update → install Docker → pull n8n
   and cloudflared images → start containers → run n8n DB migrations.
5. **Recovery time budget:**
   - Cold start (scratch boot): ≤ 17 min (600s initial_delay + 50s
     detection + ~6 min startup).
   - Warm replace (template change, no initial_delay): ≤ 6 min.
   - See the [SLO section](#slo--sli) for the SLI-side target (10 min).
6. Zero manual intervention required.

## Stack

| Component | Technology | Why |
|---|---|---|
| IaC | Terraform | Reproducible infra |
| Compute | GCP e2-micro | Free Tier (always free) |
| Self-healing | MIG + Health Check | Auto-replace crashed VM |
| Workflow engine | n8n | Open-source automation |
| Database | Cloud SQL PostgreSQL | Persistent state |
| Secrets | GCP Secret Manager | No plaintext credentials |
| Tunnel | Cloudflare Tunnel | HTTPS without public IP |
| CI/CD | GitHub Actions + WIF | Keyless authentication |

## Prerequisites

- GCP project with billing enabled
- GCS bucket for Terraform state
- Cloud SQL PostgreSQL instance
- Cloudflare Tunnel token
- GitHub repository secrets configured

## Quick Start

### 1. Clone & configure

```bash
git clone https://github.com/oleiarme/gcp-self-healing-infra.git
cd gcp-self-healing-infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 2. Create backend config (never commit this file)

```bash
cat > backend.conf <<EOF
bucket = "your-terraform-state-bucket"
prefix = "terraform/state"
EOF
```

### 3. Deploy locally

```bash
terraform init -backend-config=backend.conf
terraform plan
terraform apply
```

### 4. Deploy via GitHub Actions

Add these to **Settings → Secrets and variables → Actions**:

**Secrets:**
| Name | Description |
|---|---|
| `WIF_PROVIDER` | Workload Identity Federation provider |
| `WIF_SA` | Service account email for WIF |
| `TF_BACKEND_BUCKET` | GCS bucket name for Terraform state |
| `TF_VAR_CF_TUNNEL_TOKEN` | Cloudflare Tunnel token |
| `TF_VAR_db_password` | PostgreSQL password |
| `TF_VAR_n8n_encryption_key` | n8n encryption key (random 32-char string) |

**Variables (non-secret):**
| Name | Description |
|---|---|
| `TF_VAR_project_id` | GCP project ID |
| `TF_VAR_db_host` | Cloud SQL private IP |
| `TF_VAR_db_user` | PostgreSQL username |

Push to `main` → CI/CD deploys automatically.

## Free Tier Compliance

- **VM**: e2-micro (2 vCPU, 1 GB RAM) — always free in us-central1
- **Disk**: 30 GB standard — within free tier
- **Network**: STANDARD tier
- Built-in guard checks disk/VM count before every apply

## SLO / SLI

| Metric | Target | How measured |
|--------|--------|--------------|
| **Availability** | 99.5% / month | GCP health check: 2 successes → healthy, 5 failures → unhealthy |
| **Recovery time** | < 10 min | MIG detects failure → replaces VM → startup.sh completes |
| **Health check interval** | 10s | GCP polls `/healthz` every 10s with 5s timeout |
| **Startup grace period** | 420s | Docker `start_period` before n8n reports healthy/unhealthy |

**Error budget:** 3.6h downtime/month (0.5%) is acceptable.
If MIG recreates VM more than ~3 times/month → investigate root cause (see [Runbook](Runbook.md)).

**What this does NOT cover:**
- Cloud SQL availability (managed by GCP, separate SLA)
- Cloudflare Tunnel availability
- Network partition between VM and database

## Outputs

After `terraform apply`, get key resource names for debugging and alerting:

```bash
terraform output -json | jq '{
  mig_name,
  health_check_name,
  vm_service_account_email,
  secret_names
}'
```

| Output | Use case |
|--------|----------|
| `mig_name` | Identify MIG in GCP Console |
| `health_check_name` | Set up Cloud Monitoring alerting |
| `vm_service_account_email` | Filter logs by service account |
| `secret_names` | Quick reference for rotation script (Scenario 3 in Runbook) |
| `deployment_timestamp` | Correlate changes across environments |

## Runbook

For incident response procedures see [Runbook.md](Runbook.md):
- **Scenario 1:** MIG recreated VM (health check failed)
- **Scenario 2:** Startup timeout / boot-loop
- **Scenario 3:** Secret rotation (DB password, n8n key, Cloudflare token)
- **Scenario 4:** MIG update / terraform redeploy

## Project Structure

```
.
├── .github/
│   └── workflows/
│       └── deploy.yml        # CI/CD pipeline
│       └── terraform.yml     # terrafrom validate
├── scripts/
│   └── startup.sh            # VM bootstrap script
├── terraform/
│   ├── main.tf # Core infrastructure
│   ├── variables.tf # Input variables
│   ├── outputs.tf # Terraform outputs for debugging/alerting
│   └── terraform.tfvars.example # Config template
├── Runbook.md # Incident response procedures
└── README.md
```
