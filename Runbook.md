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
  --zone=us-central1-a \
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
  --zone=us-central1-a \
  --instances=$(gcloud compute instance-groups managed list-instances n8n-mig \
    --zone=us-central1-a --format="value(instance)") \
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
  --zone=us-central1-a \
  --instances=$(gcloud compute instance-groups managed list-instances n8n-mig \
    --zone=us-central1-a --format="value(instance)") \
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
  --zone=us-central1-a \
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

## Quick Reference

| Command | When |
|---------|------|
| `docker compose ps` | Check container status |
| `docker compose logs n8n --tail=50` | n8n errors |
| `cat /var/log/startup.log` | Full startup trace |
| `gcloud compute instance-groups managed list-instance-events n8n-mig --zone=us-central1-a` | MIG events (recreates) |
| `gcloud logging read 'logName:"startup"' --limit=20` | Recent startups |
| `curl -sf http://localhost:5678/healthz` | Health check locally |