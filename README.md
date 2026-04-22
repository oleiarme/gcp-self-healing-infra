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

## Security Posture

(Phase 3 of [`docs/slo-roadmap.md`](docs/slo-roadmap.md). All controls below are codified in `terraform/` or `.github/`; no manual console clicks.)

### Identity & access (least-privilege)

| Identity | OAuth scope on VM | Explicit IAM bindings |
|---|---|---|
| `n8n-app-sa` (VM SA) | `cloud-platform` (required for Secret Manager — no narrower scope exists) | `roles/logging.logWriter`, `roles/monitoring.metricWriter` (project-wide), `roles/secretmanager.secretAccessor` per-secret on each of the 3 secrets — **never** project-wide |
| GitHub Actions deployer | n/a (federated) | Whatever role the WIF SA holds — should be ≤ `roles/editor` on this single project |

The "intersection of OAuth scope ∩ IAM bindings" model means a future role accidentally granted to `roles/editor` would still be useless without re-applying the SA scope; conversely, a future per-resource binding (e.g. on a new secret) is opt-in for this VM. Both layers must agree to grant a permission.

### WIF (keyless) attribute condition

The WIF provider is created out-of-band (not in this repo) but **must** be created with an attribute condition that pins it to this repository on the protected branch. The variables `wif_allowed_repository` and `wif_allowed_ref` in `terraform/variables.tf` document the canonical values. Reference command for the operator:

```bash
gcloud iam workload-identity-pools providers update-oidc github \
  --workload-identity-pool=github-pool \
  --location=global \
  --attribute-condition='assertion.repository == "kwonvkim-collab/gcp-self-healing-infra" && assertion.ref == "refs/heads/main"'
```

Without this condition, **any fork** could mint a token for the deploy SA. With it, only pushes on `main` of this repo can.

### Secrets

- Stored in **Google Secret Manager** with `user_managed` replication pinned to `us-central1`. No plaintext in Terraform state for secret values (variable types are `sensitive = true` and the values land directly in `secret_data`).
- Each secret has `lifecycle.prevent_destroy = true`. `terraform destroy` cannot wipe a credential that the running VM depends on; an intentional decommission requires `terraform state rm` first.
- The `n8n-app-sa` Service Account is also `prevent_destroy` — recreating it would orphan every per-secret IAM binding.
- IAM bindings on secrets are explicit `google_secret_manager_secret_iam_member` (per-secret), never `_iam_policy` (which is destructive).

### Container image pinning

Both container images run on the VM are pinned by **SHA256 digest** in addition to a human-readable tag, so a re-issued tag (e.g. `cloudflared:2026.3.0` rebuilt with new layers) cannot silently change what runs in production.

| Image | Variable | Pinned to |
|---|---|---|
| n8n | `var.n8n_image` | `docker.n8n.io/n8nio/n8n:2.16.1@sha256:ad20607c…` |
| cloudflared | `var.cloudflared_image` | `cloudflare/cloudflared:2026.3.0@sha256:6b599ca3…` |

Digests are kept fresh by `.github/workflows/digest-refresh.yml`: a scheduled GitHub Actions job (weekly, Mondays 06:00 UTC) that re-resolves both image digests with `crane digest`, runs `terraform validate` against the new refs, and opens a review PR via `peter-evans/create-pull-request` when either digest has moved. Dependabot itself is deliberately **not** used for these images — its `docker` ecosystem only scans Dockerfiles and docker-compose files, neither of which exists in this repo; the digests live inside Terraform variable defaults which no Dependabot ecosystem understands. Manual refresh is also supported: `bash scripts/refresh-digests.sh` does exactly what the workflow does and updates `variables.tf` in place.

### Deploy gate

`Settings → Environments → production` must be configured with **at least one required reviewer** and the `deploy.yml` workflow declares `environment: production` so every `terraform apply` is interactive-approved by a human. Recommended additional protections: 5-minute wait timer; restrict to `main`; restrict to repository admins.

### Static analysis in CI (`.github/workflows/terraform.yml`)

| Check | Tool | Purpose |
|---|---|---|
| `terraform fmt` | terraform | enforces canonical formatting |
| `terraform validate` | terraform | catches schema/type errors before plan |
| `tflint` | terraform-linters/setup-tflint + Google ruleset | catches deprecated args, unused variables, GCP-specific footguns |
| `tfsec` | aquasecurity/tfsec-action | security misconfigurations (open ports, plaintext secrets, missing encryption, public buckets) |
| `Checkov` | bridgecrewio/checkov-action | second-opinion policy scanner; intentional overlap with tfsec for defence in depth |
| `shellcheck` | direct binary | startup.sh sanity (suppresses SC2154 because Terraform interpolations look like shell vars) |

`tfsec` runs with `soft_fail=false` — any HIGH/CRITICAL finding blocks the PR. Suppress legitimately-skipped findings inline with `tfsec:ignore:<rule_id>` and a comment explaining why; do not suppress them in workflow config.

### Supply chain

- All Actions in workflows are pinned by major version (`@v4` etc.). Dependabot (`.github/dependabot.yml`) groups weekly minor + patch bumps into one PR.
- Container image digests (`var.n8n_image`, `var.cloudflared_image`) refreshed weekly by `.github/workflows/digest-refresh.yml` (`crane digest` → `terraform validate` → `peter-evans/create-pull-request`). Dependabot's `docker` ecosystem is deliberately not used here because it cannot parse Terraform variable defaults — see the “Container image pinning” subsection above for the full rationale and the manual `bash scripts/refresh-digests.sh` fallback.



## Resilience & DR

(Phase 4 of [`docs/slo-roadmap.md`](docs/slo-roadmap.md). Operational procedures live in [Runbook §5](Runbook.md#5-backup--dr).)

### Regional MIG

The Managed Instance Group is defined as `google_compute_region_instance_group_manager` on `us-central1` with `distribution_policy_zones = ["us-central1-a", "us-central1-b", "us-central1-f"]`. `target_size = 1`, so at any instant exactly one e2-micro runs — Free-Tier compliant — but on a zonal incident the MIG's autohealing policy recreates the VM in a surviving zone instead of staying dead in the blast-radius zone. Expected **zonal-failover MTTR ≈ cold-start MTTR (~17 min worst case)** because the replacement path always runs full `startup.sh` on a fresh VM; if a zonal incident outlasts the SLO's 1-hour fast-burn window the fast-burn alert fires through the same email channel as every other SLO breach. **What this does not cover:** a full `us-central1` region outage. That would require a pre-provisioned standby in another region (out of Free Tier) or a manual Terraform re-apply in a fresh project pointed at a different region — accepted risk for this repo's cost envelope.

### Cloud SQL PITR

Cloud SQL PostgreSQL runs with PITR enabled, retention 7 days (Cloud SQL default). Restore procedure: [Runbook §5.1](Runbook.md#51-cloud-sql-point-in-time-recovery). **PITR always clones to a sibling instance — we never restore in place so the original is preserved for forensics.**

### Terraform state rollback

The GCS bucket that holds `terraform.tfstate` has **object versioning enabled** and a lifecycle rule that keeps the last 30 non-current versions for up to 90 days. Every `terraform apply` therefore produces a rollback-able snapshot of state. See [`terraform/backend.conf.example`](terraform/backend.conf.example) for the one-shot `gcloud storage buckets …` bootstrap commands, and [Runbook §5.2](Runbook.md#52-terraform-state-rollback) for the restore procedure (`gcloud storage cp gs://<bucket>/<prefix>/default.tfstate#<generation> …`).

### Secret version restore

Each `google_secret_manager_secret` has `lifecycle { prevent_destroy = true }` (Phase 3), so the secret resource itself cannot be wiped by `terraform destroy`. Individual *versions* stay disposable via `gcloud secrets versions disable|enable`: full procedure in [Runbook §5.3](Runbook.md#53-secret-version-restore).

### Cost guardrail

A `google_billing_budget` watches the project and alerts the on-call email channel (reused from Phase 2) at **50 / 90 / 100 %** of `var.monthly_budget_usd` (default `$5`). The budget amount is intentionally narrow — any steady-state spend above this is either a misconfiguration (accidental VM size bump, surprise egress) or a conscious scaling decision that should be explicit in a PR. Handling matrix: [Runbook §5.5](Runbook.md#55-billing-budget-alert).

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
| **Availability** | 99.5% over 28d rolling | External uptime check on `https://<n8n_public_host>/healthz`, 6 probe locations, 60s period (see `terraform/monitoring.tf`) |
| **Recovery time** | Cold ≤ 17 min, Warm ≤ 7 min | `initial_delay_sec` + HC detection + startup.sh — see [How Self-Healing Works](#how-self-healing-works) |
| **In-cluster HC interval** | 10s | GCP polls `/healthz` every 10s with 5s timeout |
| **Startup grace period** | 420s | Docker `start_period` before n8n reports healthy/unhealthy |

**Error budget:** 3.6h downtime/month (0.5%) is acceptable.
If the 28d error budget is consumed > 50% → weekly reviews until month end.
If consumed 100% → release freeze per `docs/error-budget-policy.md` (Phase 5).

**What this does NOT cover:**
- Cloud SQL availability (managed by GCP, separate SLA)
- Cloudflare Tunnel availability (status.cloudflare.com)
- Network partition between VM and database

## Observability & Alerting

Defined as code in `terraform/monitoring.tf` and `terraform/dashboards.tf`.

### External SLI probe
`google_monitoring_uptime_check_config.n8n` hits `https://<n8n_public_host>/healthz` every 60s from all default probe locations and requires a 2xx response whose body contains `ok`. This is the single source of truth for the 99.5% availability SLI.

### Burn-rate alerts (multi-window, multi-burn-rate, Google SRE Workbook)

| Policy | Signal | Burn rate | Trigger | Severity | Channels |
|---|---|---|---|---|---|
| `n8n SLO fast burn` | uptime good-fraction < 0.928 over **1h** | 14.4× (2% of 28d budget / 1h) | within 1h window | **CRITICAL** | email |
| `n8n SLO slow burn` | uptime good-fraction < 0.97 over **6h** | 6× (5% of 28d budget / 6h) | within 6h window | WARNING | email |
| `n8n startup script CRITICAL` | log-based metric `n8n/startup_critical` > 0 in 5m | n/a | 1 event | WARNING | email |

All alert policies carry a `runbook` user-label that deep-links to `Runbook.md` so the on-call engineer lands on the triage page directly from the alert.

### Notification channels
- `TF_VAR_oncall_email` — required. Primary on-call email.
- **Slack** — intentionally deferred. A Slack incoming-webhook URL embeds its own auth token in the path, which would leak through Terraform state and the Cloud Monitoring API if plumbed into a `webhook_tokenauth` channel. Slack delivery will be added in a later phase using the native `type = "slack"` channel with an OAuth token held in `sensitive_labels`.

### Log ingestion
`scripts/startup.sh` installs the Ops Agent with a deliberately **logging-only** config (`/etc/google-cloud-ops-agent/config.yaml`). Host- and process-metrics receivers are off — they exceeded the e2-micro IO budget historically (commit `del ops agent not enouth io`). The single tail receiver on `/var/log/startup.log` is what feeds the `n8n/startup_critical` log-based metric.

### Dashboard
`google_monitoring_dashboard.n8n_slo` is rendered from `terraform/dashboards/n8n-slo.json.tftpl` and carries four tiles: uptime good-fraction, 1h/6h burn rate with alert thresholds, MIG instance count, and startup CRITICAL events counter. The `dashboard_id` output gives a direct link.

### Design note on `google_monitoring_slo`
A formal `google_monitoring_slo` resource is intentionally **not** created in this phase — the SLO report-card semantics for boolean uptime metrics (windows-based vs request-based ratio) warrant their own review. Burn-rate alerting does not need that resource; both alert policies compute the burn rate directly from the uptime-check metric via MQL, which is the canonical, unambiguous definition. The SLO resource can be added later for the Cloud Monitoring UI report without changing alerting behaviour.

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
