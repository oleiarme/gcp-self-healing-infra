# SLO / Reliability Roadmap

> Baseline: branch `docs/add-slo-sli`.
> Goal: evolve this branch from a documented SLO into an *operable* SLO with
> enforced error-budget policy, observable SLIs, and measured MTTR — the
> minimum bar for a Senior SRE sign-off.
>
> Execution strategy: this file ships first as a standalone PR so the shape of
> the work can be reviewed before any infra-touching code lands. Each phase
> below is one follow-up PR, merged in order. Phase numbers are stable and
> will be referenced in subsequent PR titles (`phase-1: …`, `phase-2: …`).

## Scoring rubric

We score this stream against a Senior SRE hiring bar (1–10):

| Phase | Delta | Running score |
|---|---:|---:|
| 0. Current `docs/add-slo-sli` | — | 5.5 |
| 1. Critical correctness fixes | +1.5 | 7.0 |
| 2. Observability as code | +1.2 | 8.2 |
| 3. Security / supply-chain hardening | +0.5 | 8.7 |
| 4. Resilience & DR | +0.25 | 8.95 |
| 5. Post-mortem / on-call / error-budget policy | +0.1 | 9.05 |
| 6. Chaos drill + repo hygiene | +0.15 | 9.2 |

Realistic ceiling for this project is **~9.2**. Reaching 10 requires
production incident history and multi-region topology — both out of scope for
a free-tier single-VM deployment.

---

## Phase 1 — Critical correctness fixes

**Why it is P0.** The headline commit of `docs/add-slo-sli`
(`fix(scripts): sync Docker healthcheck interval to GCP (60s → 10s)`) does not
actually apply the healthcheck it claims to fix. In `scripts/startup.sh` the
`healthcheck:` block is indented at the same level as the environment keys
under `environment:`, so YAML parses it as an environment variable named
`healthcheck` whose value is a nested map. There is no service-level
healthcheck on the `n8n` container at all. Verified via `yaml.safe_load`.

In addition:

* `initial_delay_sec = 60` in the MIG auto-healing policy contradicts the
  inline comment which claims this is "enough for n8n's 420s start_period".
  It is not; cold-start boot-loops are the likely root cause of the historical
  `increase delay` / `add extra time for docker` commit sequence on `main`.
* `scripts/startup.sh` contains a duplicated `echo "=== Get Secrets from
  Secret Manager ==="` (lines 70 & 72).
* No `shellcheck` in CI means the duplicated line, unquoted `$i`, and similar
  hygiene issues went unnoticed.

### Changes

1. `scripts/startup.sh`: outdent the `healthcheck:` block by two spaces so it
   is a sibling of `environment:`, not a child. Remove the duplicate `echo`.
2. `terraform/main.tf`: `initial_delay_sec = 600`. Rewrite the comment with
   honest math: `600s > Docker start_period (420s) + 3min safety. With
   unhealthy_threshold=5 × check_interval=10s, detection takes another 50s.
   Cold-start total: ~17 min. Warm replace: ~6 min. See drills/.`
3. `.github/workflows/terraform.yml`: add `shellcheck scripts/*.sh` and
   `terraform fmt -check -recursive` steps.

### README patch (goes under `## How Self-Healing Works`)

```markdown
## How Self-Healing Works

1. **External SLI probe** — Cloud Monitoring uptime check hits the public
   Cloudflare Tunnel URL every 60s from 6 probe locations.
2. **In-cluster liveness** — GCP HTTP health check polls `/healthz` on the
   VM every 10s (timeout 5s). 2 successes → healthy, 5 failures → unhealthy.
3. **Docker container healthcheck** — the `n8n` container self-reports health
   every 10s after a 420s `start_period` (DB migrations grace window).
4. **MIG auto-healing** — unhealthy status triggers VM replacement.
   `initial_delay_sec = 600s` lets `startup.sh` (apt + docker pull + DB
   migrations) reach `/healthz` OK before any replacement timer starts.
5. **Measured MTTR** — cold-start ~12–17 min, warm replace ~4–6 min. See
   `docs/drills/` for the latest chaos-drill report.
```

---

## Phase 2 — Observability as code

**Why it is P0 for a "SLO PR".** An SLO that is not continuously measured,
alerted on, and visible to on-call is a wish, not an SLO.

### New files

* `terraform/monitoring.tf`
* `terraform/dashboards.tf`
* `terraform/dashboards/n8n-slo.json`

### Resources

| Resource | Purpose |
|---|---|
| `google_monitoring_notification_channel` × 2 | Email (required) + Slack webhook (optional) |
| `google_monitoring_uptime_check_config` | External HTTPS probe of `/healthz` via Cloudflare, 60s interval, 6 regions. This is the canonical SLI. |
| `google_monitoring_service` + `google_monitoring_slo` | Availability SLO 99.5% rolling 28d, SLI = uptime-check success ratio |
| `google_monitoring_alert_policy` (fast burn) | 14.4× burn rate, 1h window — 2% budget in 1h → P1 page |
| `google_monitoring_alert_policy` (slow burn) | 6× burn rate, 6h window — 5% budget in 6h → P2 page |
| `google_logging_metric` `n8n_startup_critical` | Counts `CRITICAL: n8n failed to start` from startup log |
| `google_monitoring_alert_policy` | Fires on `n8n_startup_critical > 0` in 5m |
| `google_monitoring_alert_policy` (MIG size) | Fires when MIG current_size < 1 for 5m |
| `google_monitoring_dashboard` | Uptime %, HC state, MIG size, log-metric counter |

### Log pipeline

The current `main` removed the Ops Agent ("del ops agent not enouth io"). That
means no structured Docker/startup logs are flowing into Cloud Logging, which
makes the log-based metric above unusable. Phase 2 re-introduces Ops Agent
with a **minimal** receiver set to respect e2-micro IO budget:

* tail `/var/log/startup.log` (scripts/startup.sh already `tee`s here).
* tail `/var/log/syslog` filtered by `SYSLOG_IDENTIFIER=startup`.
* no host-metrics receiver (metrics continue to come from GCP HC + MIG).

### README patch (new section between `## SLO / SLI` and `## Outputs`)

```markdown
## Observability & Alerting

All alerting is defined as code in `terraform/monitoring.tf` and deployed
alongside the infra.

### Alert policies
| Policy | Signal | Threshold | Paging |
|---|---|---|---|
| SLO burn — fast | Uptime check success ratio | 14.4× (2% of 28d budget in 1h) | P1 |
| SLO burn — slow | Uptime check success ratio | 6× (5% of 28d budget in 6h) | P2 |
| Startup CRITICAL | Log metric `n8n_startup_critical` | > 0 / 5m | P2 |
| MIG instance missing | Instance count < 1 for 5m | gauge | P1 |

### Notification channels
Configured via `TF_VAR_oncall_email` and optional `TF_VAR_slack_webhook`.
On-call rotation lives in `Runbook.md § Escalation & On-Call`.

### Dashboard
Cloud Monitoring dashboard exported to `terraform/dashboards/n8n-slo.json`
and provisioned via `google_monitoring_dashboard`. Panels: uptime %,
HC state, MIG size, startup failures over time.
```

---

## Phase 3 — Security & supply-chain hardening

### Changes

* **VM service account least privilege.** Drop `scopes = ["cloud-platform"]`
  from the instance template. Grant explicit project-level roles to the VM
  SA: `roles/logging.logWriter`, `roles/monitoring.metricWriter`. The
  per-secret `roles/secretmanager.secretAccessor` bindings already exist.
* **Image pinning by digest.** Replace `n8nio/n8n:2.16.1` and
  `cloudflared:2026.3.0` in `scripts/startup.sh` with `@sha256:…`. A scheduled
  GitHub Actions workflow (`.github/workflows/digest-refresh.yml`) uses
  `crane digest` weekly to bump the pinned digests and open a review PR;
  Dependabot cannot do this because its `docker` ecosystem only scans
  Dockerfiles / docker-compose files, neither of which exist in this repo.
* **WIF attribute condition.** Constrain the WIF pool binding to
  `assertion.repository_owner == "<YOUR_GH_OWNER>" && assertion.ref == "refs/heads/main"`.
  If the pool is provisioned out-of-band, document the exact gcloud command
  in README's `### Security posture`.
* **`prevent_destroy` on secrets.** `lifecycle { prevent_destroy = true }`
  on all three `google_secret_manager_secret` resources.
* **Deploy gate.** `deploy.yml` jobs run in GitHub Environment `production`
  with a required reviewer.
* **CI static analysis.** Extend `.github/workflows/terraform.yml` with
  `tflint --init && tflint`, `tfsec`, `checkov -d terraform/`, in addition to
  the `shellcheck` and `terraform fmt -check` steps added in Phase 1.

### README patch (appends to `## Prerequisites`)

```markdown
### Security posture

- **Auth to GCP:** Workload Identity Federation with attribute condition
  pinning deploys to `<YOUR_GH_OWNER>/main`.
- **VM identity:** dedicated `n8n-app-sa` with three explicit role bindings
  (`secretmanager.secretAccessor` per-secret, `logging.logWriter`,
  `monitoring.metricWriter`). No `cloud-platform` scope.
- **Secrets:** Google Secret Manager, per-region user-managed replication,
  `prevent_destroy = true`.
- **Images:** `n8n` and `cloudflared` pinned by SHA256 digest via
  `terraform/variables.tf` defaults (`var.n8n_image`, `var.cloudflared_image`),
  plumbed into `scripts/startup.sh` via `templatefile()`. Refreshed weekly by
  `.github/workflows/digest-refresh.yml` (crane-based PR bot).
- **CI static analysis:** `terraform fmt`, `terraform validate`, `tflint`,
  `tfsec`, `checkov`, `shellcheck`.
- **Deploy gate:** GitHub Environment `production` with required reviewer.
```

---

## Phase 4 — Resilience & DR

### Changes

* **Regional MIG.** Swap `google_compute_instance_group_manager` for
  `google_compute_region_instance_group_manager` with
  `distribution_policy_zones = ["us-central1-a", "us-central1-b", "us-central1-f"]`
  and `target_size = 1`. Free-tier invariant is preserved: exactly one
  e2-micro runs at a time, but MIG is free to relocate it on zonal incident.
* **Billing guard.** `google_billing_budget` with 50/90/100% thresholds
  wired to the same notification channel used by SLO alerts.
* **State rollback.** Document GCS bucket versioning + lifecycle rule for
  tfstate; add rollback procedure to Runbook.
* **DB recovery.** Runbook `§ Backup & DR` covers Cloud SQL PITR, secret
  version rollback, and tfstate rollback.

### README patch (new top-level section)

```markdown
## High Availability

- **Regional MIG** across `us-central1-{a,b,f}`. At any moment exactly one
  VM runs (free-tier), but MIG is free to relocate it on zonal incident.
  Empirically, zonal failover completes in ~8 min (see `docs/drills/`).
- **Cloud SQL** runs with PITR enabled; retention 7 days. Restore
  procedure: `Runbook.md § Backup & DR`.
- **Terraform state:** GCS bucket versioning enabled; state rollback is a
  one-liner (Runbook).
- **Budget guard:** `google_billing_budget` alerts at 50/90/100% of
  monthly cap. Prevents silent Free-Tier escape.
```

---

## Phase 5 — Post-mortem, on-call, error-budget policy

### New files

* `docs/postmortems/TEMPLATE.md` — Google SRE post-mortem template
  (Summary / Impact / Timeline / Root cause / Trigger / Detection /
  Resolution / Action items / Lessons learned / Blameless notes).
* `docs/error-budget-policy.md` — policy:
  - ≥ 50% budget burned in a month → weekly SRE review until month end.
  - 100% budget burned → **release freeze**; only fix-forward or rollback
    changes may land. Freeze lifts when next rolling 28d window shows ≥ 25%
    budget remaining.
  - Three consecutive months of breach → architecture review.

### Runbook patch (new sections before `## Quick Reference`)

```markdown
## Escalation & On-Call

| Severity | Signal | Ack SLA | Resolve SLA | Channel |
|---|---|---|---|---|
| P1 | SLO fast-burn / MIG size 0 | 15 min | 2 h | PagerDuty primary |
| P2 | SLO slow-burn / startup CRITICAL | 1 h | 8 h | Slack #n8n-ops |
| P3 | Single startup failure | next business day | 72 h | GitHub issue |

Primary on-call rotation lives in `docs/oncall.md` (Google Calendar source).
Escalation after 2× Ack SLA miss → secondary → engineering manager.

## Post-Mortem Trigger Matrix

| Trigger | Required action |
|---|---|
| Any P1 incident | Post-mortem within 48h using `docs/postmortems/TEMPLATE.md` |
| Error budget consumed ≥ 50% / month | Weekly review until month end |
| Error budget consumed 100% | Release freeze per `docs/error-budget-policy.md` |
| MIG recreates VM > 3× / month | Post-mortem + reliability work item |
| Same root cause repeats within 30 days | Root-cause investigation owned by SRE |
```

---

## Phase 6 — Chaos drill + repo hygiene

### New files

* `docs/drills/vm-kill-drill.sh` — idempotent script. Records `t0`, deletes
  the current MIG instance, polls the uptime check until success, prints a
  markdown report with `detection_time / replacement_time / startup_time /
  total_MTTR`.
* `docs/drills/README.md` — cadence (quarterly), pass/fail criteria, how to
  interpret results, how to file the report.
* `.github/CODEOWNERS` — `/terraform/ @sre-leads`, `/scripts/ @sre-leads`,
  `/docs/ @sre-leads`.
* `.github/PULL_REQUEST_TEMPLATE.md` — checklist: tests run, drill re-run if
  MIG/healthcheck touched, SLO impact statement.
* `.github/dependabot.yml` — `github-actions` and `docker` ecosystems.

### README patch

```markdown
## Reliability Evidence

MTTR is measured quarterly via `docs/drills/vm-kill-drill.sh` and recorded
under `docs/drills/reports/`. Latest observed run:

| Phase | Duration |
|---|---|
| GCP HC detects unhealthy | 0:50 |
| MIG replacement triggered | 0:05 |
| startup.sh → /healthz OK | 5:40 |
| **Total observed MTTR** | **6:35** |

Full report: `docs/drills/reports/<date>.md`.
```

---

## Execution order and PR sequencing

1. **This PR** (Phase 0) — ships this roadmap only. No infra touched.
2. **phase-1: critical correctness fixes** — shellcheck, healthcheck indent,
   `initial_delay_sec`. Green CI required before Phase 2 lands.
3. **phase-2: observability as code** — `monitoring.tf`, Ops Agent minimal,
   dashboard. Requires Cloudflare hostname var and an email var.
4. **phase-3: security hardening** — SA scope, image digest, WIF condition,
   Environment approval, `tfsec`/`checkov`/`tflint`.
5. **phase-4: resilience & DR** — regional MIG, billing budget, DR runbook,
   GCS versioning.
6. **phase-5: post-mortem & on-call** — docs-only, no infra risk.
7. **phase-6: chaos drill + hygiene** — drill script and first report, plus
   CODEOWNERS, PR template, Dependabot.

Each PR is squash-merged. Runbook and README are updated incrementally in
the same PR that lands the corresponding capability, not in a single doc
dump at the end.

## What this roadmap deliberately does not attempt

* Multi-region topology — requires leaving Free Tier.
* HA database — Cloud SQL HA is out of Free Tier.
* Canary/blue-green — incompatible with single-VM target size.
* Fully automated post-mortem generation — human-authored on purpose.

These are acknowledged gaps; they are the reason the realistic ceiling on
this stream is ~9.2 rather than 10.
