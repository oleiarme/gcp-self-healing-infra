# Runbook: n8n Self-Healing Infrastructure

Incident playbook for n8n on GCP MIG. Each scenario covers: symptoms, diagnosis, resolution, and post-mortem trigger.

**SLO:** 99.5% availability / month. Error budget: 3.6h downtime/month.
If downtime exceeds budget → start post-mortem within 48h.

---

## 1. MIG Recreated VM (Health Check Failed)

### Symptoms
- MIG shows instance recreation in GCP Console → Instance Groups → n8n-mig → Events
- Health check status: `UNHEALTHY`
- Startup logs show `❌ CRITICAL: n8n failed to start within 10 minutes`

### Diagnosis
```bash
# 1. When did it happen?
gcloud logging read \
  'resource.type="gce_instance" AND jsonPayload.message:"n8n" AND jsonPayload.message:"CRITICAL"' \
  --project=$PROJECT_ID \
  --format="table(timestamp,jsonpayload.message)" \
  --order=desc \
  --limit=5

# 2. Was it a one-off or recurring?
gcloud compute instance-groups managed list-instance-events n8n-mig \
  --region=us-central1 \
  --project=$PROJECT_ID

# 3. Check logs from the crashed VM
gcloud logging read \
  'resource.type="gce_instance" AND resource.labels.instance_name=~"n8n-.*"' \
  --project=$PROJECT_ID \
  --format="table(timestamp,jsonpayload.message)" \
  --order=desc \
  --limit=50
```

### Common Causes
| Cause | Signs | Fix |
|-------|-------|-----|
| n8n OOM (e2-micro memory limit) | `OOMKilled` in docker logs | Reduce `N8N_CONCURRENCY_PRODUCTION_LIMIT` to 1 (already set), check memory after golden disk |
| Docker pull timeout | Startup log shows `timeout 1800` reached | Check network, consider golden disk with images pre-loaded |
| Database unreachable | `ECONNREFUSED` in n8n logs | Check Cloud SQL connectivity, private IP |
| Docker daemon OOM | `Cannot connect to Docker daemon` | Already mitigated by 85% CPUQuota + swap — if still happening, add memory |

### Resolution
**Self-healed automatically.** MIG replaced the VM. Verify:
```bash
# Check current VM is healthy
curl -sf http://localhost:5678/healthz && echo "n8n OK" || echo "n8n DOWN"

# Check cloudflared tunnel is running
docker compose ps
```

### Post-Mortem Trigger
If MIG recreates VM more than **3 times/month** → mandatory post-mortem.
Update SLO error budget tracker.

---

## 2. Startup Timeout (n8n Never Became Healthy)

### Symptoms
- MIG recreates VM repeatedly (boot-loop)
- Startup script logs: `⏳ Waiting for n8n to initialize (60/60)...` then `❌ CRITICAL: n8n failed to start`
- Health check fails → new VM → same cycle

### Diagnosis
```bash
# 1. Check startup logs — where exactly did it fail?
gcloud logging read \
  'logName:"startup" OR jsonpayload.logger:"startup"' \
  --project=$PROJECT_ID \
  --format="table(timestamp,jsonpayload.message)" \
  --order=desc \
  --limit=30

# 2. Docker container status
docker compose ps
docker compose logs --tail=50 n8n

# 3. Docker daemon alive?
systemctl status docker
journalctl -u docker --no-pager -n 20
```

### Common Causes & Fixes
| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| Docker pull fails / too slow | `docker compose pull` in logs | Increase timeout or use golden disk with images |
| Secrets not accessible | `Failed to fetch DB_PASSWORD` | Check VM SA has `secretmanager.secretAccessor` |
| DB unreachable from VM | `ECONNREFUSED` | Verify Cloud SQL private IP and VPC config |
| n8n crashes on first start | Docker logs show panic/panic | Check DB schema compatibility, n8n version |

### Emergency Fix (If Boot-Loop)
Temporarily set `initial_delay_sec = 2400` to give VM time to boot:
```bash
# In terraform/main.tf — MIG section
initial_delay_sec = 2400  # 40 min — only for debugging boot-loop
# After golden disk ready → revert to 60
```

### Resolution
1. Fix root cause (see table above)
2. Force MIG to recreate current VM:
```bash
gcloud compute instance-groups managed recreate-instances n8n-mig \
  --region=us-central1 \
  --instances=$(gcloud compute instance-groups managed list-instances n8n-mig \
    --region=us-central1 --format="value(instance)") \
  --project=$PROJECT_ID
```

---

## 3. Secret Rotation (DB Password / n8n Key / Cloudflare Token)

### When to Rotate
| Secret | Trigger | Frequency |
|--------|---------|-----------|
| `n8n-db-secret` | DB password changed, security incident | On-demand |
| `n8n-encryption-key` | n8n upgrade, security incident | On-demand |
| `n8n-cf-token` | Cloudflare account change, token compromised | On-demand |

> **Note:** n8n will restart after secret rotation and reconnect automatically.
> No downtime if only secrets change (Docker restart = ~30s).

### How to Rotate

```bash
PROJECT_ID="your-project-id"
SECRET_NAME="n8n-db-secret"  # or n8n-encryption-key / n8n-cf-token
NEW_VALUE="your-new-secret-value"

# 1. Add new version to Secret Manager
echo -n "$NEW_VALUE" | gcloud secrets versions add $SECRET_NAME \
  --data-file=- \
  --project=$PROJECT_ID

# 2. Trigger VM restart to pick up new secret
# (new VM will fetch latest version; existing VM needs restart)
gcloud compute instance-groups managed recreate-instances n8n-mig \
  --region=us-central1 \
  --instances=$(gcloud compute instance-groups managed list-instances n8n-mig \
    --region=us-central1 --format="value(instance)") \
  --project=$PROJECT_ID

# 3. Verify new VM started with new secret
sleep 60
curl -sf http://localhost:5678/healthz && echo "OK"
```

### If n8n Fails After Rotation (Encryption Key)
Encryption key change requires n8n restart — already handled above.
If n8n fails to start, check:
```bash
docker compose logs n8n | grep -i encryption
# If "encryption key mismatch" → restore previous key version
gcloud secrets versions list n8n-encryption-key --project=$PROJECT_ID
gcloud secrets versions access latest --secret=n8n-encryption-key --project=$PROJECT_ID
```

---

## 4. MIG Update / Terraform Redeploy

### When This Happens
- Push to `main` → GitHub Actions runs `terraform apply`
- `update_policy` = `PROACTIVE` + `RECREATE` means **VM will be replaced** on every template change

### How to Monitor
```bash
# Watch MIG events during deploy
gcloud compute instance-groups managed list-instance-events n8n-mig \
  --region=us-central1 \
  --project=$PROJECT_ID

# Check new VM is healthy
for i in {1..30}; do
  curl -sf http://localhost:5678/healthz && echo "✅ n8n healthy after redeploy" && break
  echo "⏳ Waiting... ($i/30)"
  sleep 10
done
```

### Expected Downtime
- MIG creates new VM before destroying old: ~5-7 min
- Old VM stays until new VM passes health check
- Total downtime: **< 10 min** (within SLO recovery time target)

---

## 5. Backup & DR

Incident archetypes covered here: *data loss* (Cloud SQL row-level corruption,
accidental `DROP TABLE` via n8n workflow), *state loss* (a bad `terraform apply`
destroyed the wrong resource), *secret loss* (an on-call rotated a secret and
broke production), and *zonal outage* (whole zone goes dark in the region).
Phase 4 of [`docs/slo-roadmap.md`](docs/slo-roadmap.md).

### 5.1 Cloud SQL Point-In-Time Recovery

Cloud SQL PostgreSQL runs with **PITR enabled**; retention is the Cloud SQL
default (7 days) unless explicitly overridden. PITR uses transaction log
archival under the hood — you can restore to any second within the retention
window, not just to a backup boundary.

```bash
# 1. Identify the instance and the exact restore timestamp (UTC, ISO 8601).
INSTANCE=$(gcloud sql instances list --filter="name~n8n" --format='value(name)' --project="$PROJECT_ID")
TS="2026-01-15T14:32:00Z"   # one second before the bad change

# 2. Clone to a SIBLING instance. Never restore in place — we want the
#    original around for forensics.
gcloud sql instances clone "$INSTANCE" "${INSTANCE}-restore-$(date -u +%Y%m%dT%H%M%S)" \
    --point-in-time="$TS" \
    --project="$PROJECT_ID"

# 3. Point n8n at the restored instance by updating var.db_host and running
#    terraform apply. The MIG will roll the VM through a new instance
#    template; the update_policy forces a full replace so the startup.sh
#    bootstrap re-reads Secret Manager cleanly.

# 4. After verifying n8n on the restored data, you can retire the old
#    instance. Until then keep both alive for root-cause analysis.
```

**Trigger matrix for using PITR:**

| Symptom | PITR appropriate? |
|---|---|
| n8n workflow deleted rows via a bug | yes — restore to 1s before |
| n8n container crash loop | no — fix startup.sh, don't restore data |
| CloudSQL instance deleted | yes, if within 7 days — otherwise unrecoverable |
| Rogue admin issued `DROP DATABASE` | yes, assuming you catch it within 7 days |

### 5.2 Terraform state rollback

Every `terraform apply` writes a new generation of
`gs://<bucket>/<prefix>/default.tfstate` because the GCS state bucket has
object versioning enabled (see `terraform/backend.conf.example` for the
one-shot bucket configuration). To rollback:

```bash
BUCKET=<project-id>-tfstate
PREFIX=n8n-self-healing

# 1. List generations ordered newest → oldest.
gcloud storage ls --versions "gs://${BUCKET}/${PREFIX}/default.tfstate"

# 2. Inspect the generation you want to restore (optional).
gcloud storage cp "gs://${BUCKET}/${PREFIX}/default.tfstate#<generation>" - \
    | jq '.resources[].name' | sort

# 3. Restore that generation as the new live version.
gcloud storage cp "gs://${BUCKET}/${PREFIX}/default.tfstate#<generation>" \
    "gs://${BUCKET}/${PREFIX}/default.tfstate"

# 4. Immediately run `terraform plan` from a checkout pinned to the
#    corresponding git SHA to verify the rollback matches code intent.
#    Any drift here is a real incident.
```

**Prerequisite:** the state bucket must have versioning enabled. If it
was bootstrapped without versioning, older generations are gone and this
procedure cannot recover them. Fix the bucket (`gcloud storage buckets
update --versioning`) before the next `terraform apply` so we never lose
this safety net again.

### 5.3 Secret version restore

Each Secret Manager secret keeps every version we've ever set. If a
rotation broke production:

```bash
# 1. Find the version that was live before the bad rotation.
gcloud secrets versions list n8n-encryption-key --project="$PROJECT_ID"

# 2. Disable the bad version and re-enable the previous one.
gcloud secrets versions disable  <bad_version>      --secret=n8n-encryption-key --project="$PROJECT_ID"
gcloud secrets versions enable   <previous_version> --secret=n8n-encryption-key --project="$PROJECT_ID"

# 3. Force a fresh VM so startup.sh re-reads the secret.
gcloud compute instance-groups managed recreate-instances n8n-mig \
    --region="$REGION" \
    --instances=$(gcloud compute instance-groups managed list-instances n8n-mig \
                      --region="$REGION" \
                      --project="$PROJECT_ID" \
                      --format='value(instance)') \
    --project="$PROJECT_ID"
```

The `prevent_destroy` lifecycle on each `google_secret_manager_secret`
(Phase 3) ensures the secret *resource* can't be wiped by `terraform
destroy` — but individual versions are always disposable via the CLI
above.

### 5.4 Zonal outage

Since Phase 4 the MIG is regional (`google_compute_region_instance_group_manager`)
and its `distribution_policy_zones` spans every Free-Tier-eligible zone
in `us-central1` (`a`, `b`, `f`). During a zonal incident:

1. Autohealing detects the unhealthy VM via the GCP health check (same
   policy as the in-zone case, ~50s detection).
2. MIG attempts to create a replacement in a surviving zone. Because
   `target_size = 1`, there is no scheduling contention.
3. `startup.sh` runs end-to-end on the new VM (~6 min cold), which
   dominates the recovery-time budget.

Expected zonal-failover MTTR ≈ in-zone cold MTTR ≈ **17 min worst-case**.
If a zonal incident lasts beyond the SLO's hourly fast-burn window, the
fast-burn alert will fire (same mechanism as any other uptime incident).

**What this does NOT cover:** a full `us-central1` region outage. The
stack is still single-region; recovering from a region loss requires
either a pre-provisioned standby in another region (out of Free Tier)
or restoring Cloud SQL + re-applying Terraform in a fresh project
pointing at a different region. That is an accepted risk for this
repo's Free-Tier cost envelope.

### 5.5 Billing budget alert

The monthly-cap `google_billing_budget` (Phase 4, see `main.tf`) sends
alerts at 50 / 90 / 100 % of `var.monthly_budget_usd` (default $5) to
the on-call email channel. Trigger handling:

| Threshold | Action |
|---|---|
| 50 % | Acknowledge; investigate if spend jumped outside normal (egress spike, scaling change) |
| 90 % | Page the on-call; identify root cause; decide whether to raise the budget or revert the change |
| 100 % | Incident — something is actively consuming more than the Free-Tier envelope; treat as cost-incident with post-mortem |

---

## 6. Escalation & On-Call

> The **roster** (who gets paged this week) lives in
> [`docs/oncall.md`](docs/oncall.md). This chapter covers the **paging
> rules**: which signal maps to which severity, what the SLAs are, and
> when an alert triggers a post-mortem. Notification channel wiring is
> in `terraform/monitoring.tf`.

### 6.1 Severity matrix

| Severity | Signal source | Ack SLA | Resolve SLA | Primary channel |
|---|---|---|---|---|
| **P1** | `slo_fast_burn` (14.4×), `startup_critical`, `log_ingestion_absent` | 15 min | 2 h | PagerDuty → primary phone |
| **P2** | `slo_slow_burn` (6×), repeated `startup_critical` within 24h, `monthly_cap` budget 90 % | 1 h | 8 h | Slack `#n8n-ops` |
| **P3** | Single startup failure, one-off uptime blip, `monthly_cap` budget 50 % | next business day | 72 h | GitHub issue |

Escalation on ack-SLA miss: 1× → backup on-call, 2× → engineering manager.

### 6.2 Triage checklist (valid for every P1)

Run these in order. Stop at the first procedure that gives a healthy
signal — then file the rest as appendix evidence in the post-mortem.

1. Ack the page. Open the alert in Cloud Monitoring; note the policy
   display name, the exact time it fired, and its `documentation.content`
   (every policy points at the relevant Runbook section).
2. Confirm scope: does the external uptime check still see the site?
   `gcloud monitoring uptime list-configs` + the dashboard linked in
   `terraform/outputs.tf.dashboard_id`.
3. Triage by policy:
   - `slo_fast_burn` / `slo_slow_burn` → §1 (MIG recreation) and §2
     (startup timeout) are the usual culprits.
   - `startup_critical` → §2 directly; the metric's log filter already
     identifies the VM.
   - `log_ingestion_absent` → Ops Agent broken on the VM; SSH to the
     instance and run `journalctl -u google-cloud-ops-agent`.
   - `monthly_cap` (billing) → §5.5.
4. If no procedure in this Runbook resolves within the resolve SLA,
   escalate (see 6.1) and begin a post-mortem draft in parallel.

### 6.3 Post-mortem trigger matrix

A post-mortem (using
[`docs/postmortems/TEMPLATE.md`](docs/postmortems/TEMPLATE.md)) is
**required** when any of the below are true:

| Trigger | Deadline | Owner |
|---|---|---|
| Any P1 incident, regardless of duration | Draft within 48h, FINAL within 7 days | Incident commander |
| Error budget ≥ 50 % consumed in 28d | Weekly review until month-end | Primary on-call |
| Error budget 100 % consumed | Immediate — release freeze active per [`docs/error-budget-policy.md`](docs/error-budget-policy.md) | Primary on-call + eng manager |
| MIG recreates the VM > 3× in one calendar month | FINAL within 7 days | Primary on-call |
| Same root cause recurs within 30 days of a prior post-mortem | FINAL within 7 days; links to the prior post-mortem | Primary on-call |

The on-call reviews action items from open post-mortems weekly until all
P1 items are merged. Error budget consumption tables are the
authoritative metric, not memory.

### 6.4 What counts as an incident

Per the error-budget policy:

- **Incident** = any paging-level alert fires, **or** error budget
  consumption increases by > 5 % in a single hour, **or** the uptime
  check crosses below 99.5 % in a rolling 28-day window for the first
  time in a given window.
- **Event** (not an incident) = an anomaly that self-recovered before
  any SLA threshold and before budget consumption accelerated. Log it in
  Slack, don't file a post-mortem.

---

## Quick Reference

| Command | When |
|---------|------|
| `docker compose ps` | Check container status |
| `docker compose logs n8n --tail=50` | n8n errors |
| `cat /var/log/startup.log` | Full startup trace |
| `gcloud compute instance-groups managed list-instance-events n8n-mig --region=us-central1` | MIG events (recreates) — regional since Phase 4 |
| `gcloud logging read 'logName:"startup"' --limit=20` | Recent startups |
| `curl -sf http://localhost:5678/healthz` | Health check locally |
| `gcloud storage ls --versions "gs://<bucket>/<prefix>/default.tfstate"` | List Terraform state generations (rollback) |
| `gcloud secrets versions list <secret-id>` | List secret versions (rotation rollback) |
| `gcloud sql instances clone <inst> <inst>-restore --point-in-time=<ts>` | Cloud SQL PITR clone |