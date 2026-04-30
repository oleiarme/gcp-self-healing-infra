# Runbook: n8n Self-Healing Infrastructure

Incident playbook for n8n on GCP (Regional MIG + Stateful Disk). Each scenario covers: symptoms, diagnosis, resolution, and post-mortem trigger.

**SLO:** 99.5% availability / 28d rolling. Error budget: 3.6h downtime/month.
If downtime exceeds budget → start post-mortem within 48h.

**Architecture context:** n8n runs in Docker on a single `e2-micro` VM managed by a Regional MIG (`n8n-mig`). Postgres data lives on a persistent disk (`google-n8n-data`, `pd-standard`, `us-central1-a`) that **survives VM recreation**. The VM is replaced, not the disk.

---

## Table of Contents

1. [MIG Recreated VM (Health Check Failed)](#1-mig-recreated-vm-health-check-failed)
2. [Persistent Disk Not Attached (Startup Failed)](#2-persistent-disk-not-attached-startup-failed)
3. [Startup Timeout / Boot Loop](#3-startup-timeout--boot-loop)
4. [Application Update (In-Place Deploy)](#4-application-update-in-place-deploy)
5. [Secret Rotation](#5-secret-rotation)
6. [Infrastructure Redeploy (Terraform)](#6-infrastructure-redeploy-terraform)
7. [Backup & DR](#7-backup--dr)
8. [Billing Budget Alert](#8-billing-budget-alert)
9. [Escalation & On-Call](#9-escalation--on-call)
10. [Quick Reference](#10-quick-reference)

---

## 1. MIG Recreated VM (Health Check Failed)

### Symptoms
- MIG shows instance recreation in GCP Console → Instance Groups → n8n-mig → Events
- Health check status: `UNHEALTHY`
- Startup logs show `❌  CRITICAL` messages
- n8n URL is unreachable for > 5 minutes

### Diagnosis
```bash
PROJECT_ID="idealist-426118"
REGION="us-central1"

# 1. Check MIG status and current instance
gcloud compute instance-groups managed list-instances n8n-mig \
  --region=$REGION \
  --project=$PROJECT_ID \
  --format="table(instance.basename(), status, instanceStatus, lastAttempt.errors.errors[0].message)"

# 2. Was it a one-off or recurring?
gcloud compute instance-groups managed list-instance-events n8n-mig \
  --region=$REGION \
  --project=$PROJECT_ID

# 3. Check logs from the crashed VM
gcloud logging read \
  'resource.type="gce_instance" AND resource.labels.instance_name=~"n8n-.*"' \
  --project=$PROJECT_ID \
  --format="table(timestamp,jsonPayload.message)" \
  --order=desc \
  --limit=50

# 4. Check serial port (if VM is completely unresponsive)
INSTANCE=$(gcloud compute instance-groups managed list-instances n8n-mig \
  --region=$REGION --project=$PROJECT_ID --format="value(instance.basename())" | head -1)
gcloud compute instances get-serial-port-output $INSTANCE \
  --zone=us-central1-a --project=$PROJECT_ID | tail -50
```

### Common Causes

| Cause | Signs | Fix |
|---|---|---|
| Disk not attached (startup.sh exited) | `❌ CRITICAL: Persistent disk not attached` in logs | See §2 |
| n8n OOM on e2-micro | `OOMKilled` in docker logs | Check `docker stats`; reduce n8n workflow concurrency |
| Docker pull timeout (Docker Hub) | Startup took > 20 min | AR mirror picks up next run; check §3 |
| Database unreachable | `ECONNREFUSED` in n8n logs | Check Postgres container: `docker compose ps postgres` |
| Secrets not accessible | `Failed to fetch` in startup log | Check SA IAM binding for Secret Manager |

### Resolution
**Self-healed automatically.** MIG replaced the VM. Verify the new VM is healthy:
```bash
# Check new instance status
gcloud compute instance-groups managed list-instances n8n-mig \
  --region=us-central1 --project=$PROJECT_ID

# SSH and verify containers (once VM is RUNNING)
INSTANCE=$(gcloud compute instance-groups managed list-instances n8n-mig \
  --region=us-central1 --project=$PROJECT_ID --format="value(instance.basename())" | head -1)

gcloud compute ssh $INSTANCE --zone=us-central1-a --tunnel-through-iap \
  --command="cd /opt/n8n && docker compose ps"
```

### Post-Mortem Trigger
If MIG recreates VM more than **3 times/month** → mandatory post-mortem.

---

## 2. Persistent Disk Not Attached (Startup Failed)

### Symptoms
- Startup logs show: `⏳ Waiting for disk attachment (X/30)...` then `❌ CRITICAL: Persistent disk not attached`
- VM exits startup script immediately after the disk wait loop
- MIG tries to recreate VM repeatedly

### Why This Happens
The `startup.sh` script looks for `/dev/disk/by-id/google-n8n-data`. GCP automatically prepends `google-` to the `device_name` set in Terraform. If Terraform has `device_name = "google-n8n-data"`, Linux sees `google-google-n8n-data` (double prefix) and the disk is not found.

**Current config (correct):** `device_name = "n8n-data"` → Linux: `google-n8n-data` ✅

### Diagnosis
```bash
# SSH into the problematic VM
INSTANCE=$(gcloud compute instance-groups managed list-instances n8n-mig \
  --region=us-central1 --project=$PROJECT_ID --format="value(instance.basename())" | head -1)
gcloud compute ssh $INSTANCE --zone=us-central1-a --tunnel-through-iap \
  --command="ls -l /dev/disk/by-id/"

# What you should see:
# google-n8n-data -> ../../sdb   ← correct (one google- prefix)
# If you see google-google-n8n-data → Terraform device_name misconfigured
```

### Check Disk Is Attached to VM
```bash
gcloud compute instances describe $INSTANCE \
  --zone=us-central1-a --project=$PROJECT_ID \
  --format="json(disks)" | jq '.[].disks[].deviceName'
```

### Resolution

**If device_name is misconfigured (double prefix):**
1. Fix `main.tf`: set `device_name = "n8n-data"` in both `disk {}` block and `stateful_disk {}` block
2. Push to GitHub → `deploy.yml` recreates the VM with the correct config

**If disk genuinely not attached (e.g., MIG placed VM in wrong zone):**
```bash
# Manually attach the disk
gcloud compute instances attach-disk $INSTANCE \
  --disk=google-n8n-data \
  --zone=us-central1-a \
  --device-name=n8n-data \
  --project=$PROJECT_ID

# Then restart the startup script or just restart the VM
gcloud compute instances reset $INSTANCE --zone=us-central1-a --project=$PROJECT_ID
```

> ⚠️ **Note:** The disk `google-n8n-data` is zonal (`us-central1-a`). If the MIG places the VM in zone `b` or `f` due to a zonal incident, the disk cannot be attached. The VM will fail until zone `a` recovers. This is an accepted limitation of the Free Tier topology.

---

## 3. Startup Timeout / Boot Loop

### Symptoms
- Startup logs show the VM getting far (past disk mount) but n8n never becomes healthy
- Log: `failed to extract layer ... no space left on device`
- Or: `docker pull` hangs for > 15 minutes

### Diagnosis
```bash
# Check disk space on the VM
gcloud compute ssh $INSTANCE --zone=us-central1-a --tunnel-through-iap \
  --command="df -h && docker system df"

# Check if docker images are cached
gcloud compute ssh $INSTANCE --zone=us-central1-a --tunnel-through-iap \
  --command="docker images"
```

### Common Causes & Fixes

| Cause | Diagnosis | Fix |
|---|---|---|
| `no space left on device` during image extraction | `df -h` shows `/dev/root` > 85% full | Boot disk too small; increase to 20 GB in `main.tf` (see below) |
| Docker Hub rate limit | Pull error: `429 Too Many Requests` | Next run will use Artifact Registry mirror (populated after first successful push) |
| AR image not yet mirrored | `⚠️ AR miss` in logs, pulling from Docker Hub | Normal on first deploy; AR populated on next CI run |
| n8n crashes on startup | `docker compose logs n8n` shows panic | Check DB connectivity, encryption key, schema migration |

### Fix: Boot Disk Too Small

If you see `no space left on device`:

```
# In terraform/main.tf — disk block:
disk {
  source_image = "ubuntu-os-cloud/ubuntu-2204-lts"
  disk_size_gb = 20   # was 10 — increase to 20 GB
  auto_delete  = true
  boot         = true
}
```

**Free Tier:** 20 GB boot + 10 GB data disk = **30 GB total** (within Free Tier limit).

Push to GitHub → deploy.yml applies the change.

### Fix: Boot Loop (Extend Grace Window)

If the VM keeps getting killed by MIG before startup completes:
```bash
# Check current initial_delay_sec
grep initial_delay_sec terraform/main.tf
# Should be 1800 (30 min). If less, increase it and push.
```

---

## 4. Application Update (In-Place Deploy)

Use this to update n8n or cloudflared **without recreating the VM** (2-5 seconds downtime instead of 15-30 minutes).

### When to Use `app-deploy.yml`
- n8n version bump
- cloudflared version update
- Config changes that don't require infrastructure changes

### Step-by-Step

1. Go to **GitHub → Actions → App Deploy (In-Place) → Run workflow**
2. Fill in the inputs:
   - **n8n_image**: new image ref (e.g. `docker.n8n.io/n8nio/n8n:1.1.0@sha256:...`). Leave empty to use the current `variables.tf` default.
   - **cloudflared_image**: leave empty if not updating
   - **skip_mirror**: check only if the image is already in Artifact Registry
3. Click **Run workflow** and monitor progress

### What Happens Under the Hood
1. GitHub mirrors the new image to Artifact Registry (`us-central1-docker.pkg.dev/idealist-426118/n8n-docker/`)
2. SSH into the running VM via IAP tunnel (no public port opened)
3. Pull the new image (from AR if available, Docker Hub as fallback)
4. `sed` updates the `.env` file with the new image ref
5. `docker compose up -d --no-deps n8n` — replaces only the n8n container
6. Verifies health after 30 seconds

### After Testing: Persist the Version in Code
The in-place deploy changes the **running** container. If the VM is recreated (health check failure, zone incident), it boots with the version from `variables.tf`.

Update `terraform/variables.tf` to match the running version:
```hcl
variable "n8n_image" {
  default = "docker.n8n.io/n8nio/n8n:1.1.0@sha256:<new-digest>"
}

variable "n8n_image_tag" {
  default = "1.1.0"
}
```

Then push:
```bash
git add terraform/variables.tf
git commit -m "feat: upgrade n8n to 1.1.0"
git push
```

This triggers `deploy.yml`, which recreates the VM with the new image permanently.

---

## 5. Secret Rotation

### When to Rotate

| Secret | Secret Manager ID | Trigger |
|---|---|---|
| DB password | `n8n-db-secret` | Security incident, on-demand |
| n8n encryption key | `n8n-encryption-key` | Security incident (⚠️ data loss risk if not done carefully) |
| Cloudflare Tunnel token | `n8n-cf-token` | Cloudflare account change, token compromised |

> **Note:** After secret rotation, the **running VM still uses the old secret** from memory. You must recreate the VM to pick up the new value.

### How to Rotate

```bash
PROJECT_ID="idealist-426118"
REGION="us-central1"
SECRET_NAME="n8n-db-secret"  # or n8n-encryption-key / n8n-cf-token
NEW_VALUE="your-new-secret-value"

# 1. Add new version to Secret Manager
echo -n "$NEW_VALUE" | gcloud secrets versions add $SECRET_NAME \
  --data-file=- \
  --project=$PROJECT_ID

# 2. Also update the GitHub Secret for future deploys
# Go to: Settings → Secrets → Actions → TF_VAR_db_password (or equivalent)
# Update the value there as well.

# 3. Recreate VM to pick up new secret
INSTANCE=$(gcloud compute instance-groups managed list-instances n8n-mig \
  --region=$REGION --project=$PROJECT_ID --format="value(instance.basename())" | head -1)

gcloud compute instance-groups managed recreate-instances n8n-mig \
  --region=$REGION \
  --instances=$INSTANCE \
  --project=$PROJECT_ID

# 4. Wait and verify
sleep 300  # ~5 min for startup
gcloud compute instance-groups managed list-instances n8n-mig \
  --region=$REGION --project=$PROJECT_ID
```

### ⚠️ Encryption Key Special Case

Changing the n8n encryption key means **all existing encrypted credentials in n8n become unreadable**. Only rotate if:
- The current key is compromised
- You have no encrypted credentials in n8n OR you can re-enter them all

If n8n fails after rotation with `encryption key mismatch`:
```bash
# Roll back to previous key version
gcloud secrets versions list n8n-encryption-key --project=$PROJECT_ID

gcloud secrets versions enable <previous_version> \
  --secret=n8n-encryption-key --project=$PROJECT_ID

# Recreate VM to pick up the restored key
```

---

## 6. Infrastructure Redeploy (Terraform)

### When This Happens
- Push to `main` triggers `deploy.yml`
- Changes to `main.tf` (disk size, MIG config, network) require VM recreation
- `update_policy { replacement_method = "RECREATE" }` means old VM is **terminated then new VM created**

### Expected Timeline
| Phase | Duration |
|---|---|
| `terraform plan` review | 2-3 min |
| `terraform apply` (infra changes) | 5-15 min |
| New VM boot + startup.sh | 15-30 min (cold start) |
| n8n becomes healthy | Total: **20-45 min** |

### How to Monitor
```bash
# Watch MIG events during deploy
gcloud compute instance-groups managed list-instance-events n8n-mig \
  --region=us-central1 --project=$PROJECT_ID

# Check VM status
gcloud compute instance-groups managed list-instances n8n-mig \
  --region=us-central1 --project=$PROJECT_ID

# Watch startup logs (once VM is RUNNING)
INSTANCE=$(gcloud compute instance-groups managed list-instances n8n-mig \
  --region=us-central1 --project=$PROJECT_ID --format="value(instance.basename())" | head -1)

gcloud compute ssh $INSTANCE --zone=us-central1-a --tunnel-through-iap \
  --command="tail -f /var/log/startup.log"
```

### Disk Resize Procedure

> **Warning:** Google Cloud does not allow shrinking a disk. You can only grow it.

To shrink a disk (e.g., from 20 GB to 10 GB):
1. Temporarily set `prevent_destroy = false` in the disk lifecycle block
2. Push, let Terraform attempt the plan
3. Terraform will show `forces replacement` for the disk
4. Manually delete the disk via gcloud **before** pushing again:
   ```bash
   # Stop the MIG (detach disk)
   gcloud compute instance-groups managed resize n8n-mig --size=0 --region=us-central1

   # Wait for VM to stop (check it's gone)
   gcloud compute instances list --filter="name ~ n8n"

   # Delete the disk
   gcloud compute disks delete google-n8n-data --zone=us-central1-a --quiet
   ```
5. Push your changes → Terraform creates the new smaller disk
6. Restore `prevent_destroy = true` in a follow-up commit

---

## 7. Backup & DR

### 7.1 Postgres Backup (Manual)

The VM runs a backup script that dumps Postgres to GCS:
```bash
# Check latest backup on GCS
gcloud storage ls gs://$BACKUP_BUCKET_NAME/ | sort | tail -5

# Trigger manual backup (SSH into VM)
gcloud compute ssh $INSTANCE --zone=us-central1-a --tunnel-through-iap \
  --command="cd /opt/n8n && docker exec postgres pg_dumpall -U n8n | gzip > /tmp/n8n-manual.sql.gz && gsutil cp /tmp/n8n-manual.sql.gz gs://$BACKUP_BUCKET/manual-$(date +%Y%m%dT%H%M%S).sql.gz"
```

### 7.2 Postgres Restore from GCS Backup

```bash
# List available backups
gcloud storage ls gs://$BACKUP_BUCKET_NAME/

# Download and restore
BACKUP_FILE="n8n-backup-20260429.sql.gz"

gcloud compute ssh $INSTANCE --zone=us-central1-a --tunnel-through-iap \
  --command="
    gsutil cp gs://$BACKUP_BUCKET/$BACKUP_FILE /tmp/ &&
    docker exec -i postgres psql -U n8n -d postgres < <(gunzip -c /tmp/$BACKUP_FILE) &&
    echo '✅ Restore complete'
  "
```

### 7.3 Persistent Disk Recovery

The `google-n8n-data` disk has `prevent_destroy = true` and `delete_rule = "NEVER"`. It is **never deleted during VM recreation**.

To verify the disk exists and is intact after a VM recreation:
```bash
gcloud compute disks describe google-n8n-data \
  --zone=us-central1-a --project=$PROJECT_ID \
  --format="json(name, sizeGb, status, lastAttachTimestamp)"

# Expected output:
# "status": "READY"
# "sizeGb": "10"
```

To check data is intact after VM restart:
```bash
gcloud compute ssh $INSTANCE --zone=us-central1-a --tunnel-through-iap \
  --command="df -h /mnt/data && ls -la /mnt/data/postgres/"
```

### 7.4 Terraform State Rollback

Every `terraform apply` writes a new GCS object version. To roll back:
```bash
BUCKET="<your-tfstate-bucket>"
PREFIX="terraform/state"

# List state versions (newest first)
gcloud storage ls --versions "gs://$BUCKET/$PREFIX/default.tfstate"

# Restore a previous version
gcloud storage cp "gs://$BUCKET/$PREFIX/default.tfstate#<generation>" \
  "gs://$BUCKET/$PREFIX/default.tfstate"

# Verify the rollback
terraform plan  # should show no changes if code matches state
```

### 7.5 Secret Version Restore

Each Secret Manager secret keeps all versions. To roll back after a bad rotation:
```bash
# List versions
gcloud secrets versions list n8n-encryption-key --project=$PROJECT_ID

# Disable bad version, enable previous one
gcloud secrets versions disable <bad_version> \
  --secret=n8n-encryption-key --project=$PROJECT_ID

gcloud secrets versions enable <previous_version> \
  --secret=n8n-encryption-key --project=$PROJECT_ID

# Recreate VM to pick up the restored secret
gcloud compute instance-groups managed recreate-instances n8n-mig \
  --region=us-central1 \
  --instances=$INSTANCE \
  --project=$PROJECT_ID
```

### 7.6 Zonal Failover Limitations

The Regional MIG can relocate the VM to `us-central1-b` or `us-central1-f` if zone `a` is unavailable. **However**, the persistent disk `google-n8n-data` is zonal (`us-central1-a`). If zone `a` is unavailable:

- VM will relocate to a surviving zone ✅
- But the disk **cannot be attached** to the new VM in a different zone ❌
- n8n will **not start** until zone `a` recovers

**Mitigation options:**
1. Accept the risk (current approach, for Free Tier)
2. Restore from GCS backup to a temporary in-memory Postgres until zone `a` recovers

---

## 8. Billing Budget Alert

The optional `google_billing_budget` sends alerts at 50/90/100% of `var.monthly_budget_usd` (default $5).

| Threshold | Action |
|---|---|
| **50%** | Acknowledge; investigate if spend jumped outside normal pattern. Check for accidental egress or a forgotten resource. |
| **90%** | Page on-call. Identify root cause. Decide: raise budget or revert the change causing the spike. |
| **100%** | Incident. Something is actively consuming more than the Free-Tier envelope. Treat as cost-incident with post-mortem. |

**Common causes of unexpected spend:**
- Static IP not attached to a running VM (small hourly charge)
- Artifact Registry storage > 0.5 GB (old image versions accumulate)
- Egress traffic spike

**Check Artifact Registry storage:**
```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/idealist-426118/n8n-docker \
  --format="table(IMAGE, DIGEST, TAGS, CREATE_TIME, UPDATE_TIME)"
```

**Clean up old AR images (keep last 2 versions):**
```bash
# List and delete old digests manually via the GCP Console:
# Artifact Registry → n8n-docker → n8n → select old digests → Delete
```

---

## 9. Escalation & On-Call

> The **roster** (who gets paged this week) lives in [`docs/oncall.md`](docs/oncall.md). This section covers paging rules and severity levels.

### 9.1 Severity Matrix

| Severity | Signal | Ack SLA | Resolve SLA | Channels |
|---|---|---|---|---|
| **P1** | `slo_fast_burn` (14.4×), `log_ingestion_absent`, disk not attached | 15 min | 2 h | Email + Slack + Telegram |
| **P2** | `slo_slow_burn` (6×), > 3 VM recreations/month, budget 90% | 1 h | 8 h | Slack #n8n-ops + Telegram |
| **P3** | Single startup failure, one-off uptime blip, budget 50% | Next business day | 72 h | GitHub issue |

Escalation on ack-SLA miss: 1× → backup on-call; 2× → engineering manager.

### 9.2 Triage Checklist (P1)

Run in order. Stop at the first signal that resolves the incident:

1. **Ack** the page. Note the alert policy name and the exact fire time.
2. **Confirm scope**: is n8n reachable externally? Check the Cloud Monitoring dashboard (`terraform output dashboard_id`).
3. **Triage by signal:**
   - `slo_fast_burn` or `slo_slow_burn` → §1 (MIG recreation) or §3 (startup timeout)
   - `startup_critical` → §3 (startup timeout); the log filter identifies the exact VM
   - `log_ingestion_absent` → Ops Agent broken; SSH and run `journalctl -u google-cloud-ops-agent`
   - Disk not attached → §2
   - Budget alert → §8
4. If no procedure resolves within the SLA → escalate and begin a post-mortem draft.

### 9.3 Post-Mortem Trigger Matrix

A post-mortem (using [`docs/postmortems/TEMPLATE.md`](docs/postmortems/TEMPLATE.md)) is **required** when:

| Trigger | Deadline |
|---|---|
| Any P1 incident, regardless of duration | Draft within 48h; FINAL within 7 days |
| Error budget ≥ 50% consumed in 28d | Weekly review until month-end |
| Error budget 100% consumed | Immediate — release freeze per `docs/error-budget-policy.md` |
| MIG recreates VM > 3× in one calendar month | FINAL within 7 days |
| Same root cause recurs within 30 days | FINAL within 7 days; link to prior post-mortem |

---

## 10. Quick Reference

### Most Used Commands

```bash
# Set these once in your shell session:
export PROJECT_ID="idealist-426118"
export REGION="us-central1"
export ZONE="us-central1-a"
export INSTANCE=$(gcloud compute instance-groups managed list-instances n8n-mig \
  --region=$REGION --project=$PROJECT_ID --format="value(instance.basename())" | head -1)
```

| Command | When |
|---|---|
| `gcloud compute instance-groups managed list-instances n8n-mig --region=$REGION --project=$PROJECT_ID` | Check MIG and VM status |
| `gcloud compute instance-groups managed list-instance-events n8n-mig --region=$REGION --project=$PROJECT_ID` | MIG history (recreations, failures) |
| `gcloud compute ssh $INSTANCE --zone=$ZONE --tunnel-through-iap` | SSH into VM (no open ports) |
| `gcloud compute ssh $INSTANCE --zone=$ZONE --tunnel-through-iap --command="..."` | Run single command on VM |
| `tail -f /var/log/startup.log` | Full startup trace (run on VM) |
| `cd /opt/n8n && docker compose ps` | Container status (run on VM) |
| `cd /opt/n8n && docker compose logs n8n --tail=50` | n8n errors (run on VM) |
| `df -h && ls -la /mnt/data/postgres/` | Check disk mounted and data present (run on VM) |
| `ls -l /dev/disk/by-id/` | Verify disk symlinks (run on VM) |
| `gcloud compute instances get-serial-port-output $INSTANCE --zone=$ZONE` | Serial console (when SSH fails) |
| `gcloud logging read 'resource.type="gce_instance" AND resource.labels.instance_name=~"n8n-.*"' --project=$PROJECT_ID --limit=50` | Startup logs from Cloud Logging |
| `gcloud secrets versions list n8n-db-secret --project=$PROJECT_ID` | List secret versions |
| `gcloud compute disks describe google-n8n-data --zone=$ZONE --project=$PROJECT_ID` | Verify data disk exists |
| `gcloud storage ls --versions "gs://<bucket>/terraform/state/default.tfstate"` | List Terraform state versions |
| `gcloud compute instance-groups managed resize n8n-mig --size=0 --region=$REGION` | Stop VM (save costs) |
| `gcloud compute instance-groups managed resize n8n-mig --size=1 --region=$REGION` | Start VM |

### Health Check URLs

```bash
# From inside the VM:
curl -sf http://localhost:8080/ && echo "Health server OK"
curl -sf http://localhost:5678/healthz && echo "n8n OK"

# External check:
curl -sf https://<your-n8n-host>/healthz && echo "External OK"
```

### Disk Status Summary

```bash
# All-in-one disk status check (run from local terminal):
gcloud compute disks describe google-n8n-data \
  --zone=us-central1-a --project=$PROJECT_ID \
  --format="table(name, sizeGb, status, users[].basename())"
```