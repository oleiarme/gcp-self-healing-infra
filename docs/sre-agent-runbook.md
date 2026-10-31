# SRE Agent Procedures Runbook

Detailed operations playbook for managing the SRE diagnostic agent.

## Step 1: Disable SRE Agent (Kill-Switch)

In case of runaway LLM costs, incorrect diagnoses, or a loops during a P1 incident, the SRE Agent can be disabled.

* **Owner**: SRE on-call rotation (PagerDuty: sre-primary)
* **Duration**: 3 minutes
* **Success**: Environment variable `SRE_AGENT_ENABLED` is set to `false` and Cloud Function returns `disabled` status
* **Failure**: Cloud Function logs show `event="invocation"` after SRE_AGENT_ENABLED is updated
* **Rollback**: Set `SRE_AGENT_ENABLED` back to `true` and run Terraform apply
* **Escalation**: Lead SRE (@lead-sre)

### Action Steps
1. Navigate to GCP Console → Cloud Functions → `sre-agent`.
2. Click **Edit** → **Runtime, Build, Connections and Security Settings**.
3. Under Environment variables, update `SRE_AGENT_ENABLED` to `false`.
4. Click **Next** and then **Deploy**.
5. Alternatively, update `sre_agent.tf` locally: Set `SRE_AGENT_ENABLED = "false"`, commit and push to main.

---

## Step 2: Rotate LLM API Key

When the Gemini API key is compromised, or on a scheduled rotation, update the secret version in Secret Manager.

* **Owner**: SRE on-call rotation (PagerDuty: sre-primary)
* **Duration**: 5 minutes
* **Success**: New secret version created in Secret Manager and `sre-agent` Cloud Function is recreated
* **Failure**: Cloud Function fails to start or log shows permission/authentication error
* **Rollback**: Restore previous secret version using `gcloud secrets versions enable` and recreate Cloud Function instance
* **Escalation**: Lead SRE (@lead-sre)

### Action Steps
1. Get the new LLM API Key.
2. Update the secret version:
   ```bash
   echo -n "NEW_KEY_HERE" | gcloud secrets versions add sre-agent-llm-key --data-file=- --project="<YOUR_PROJECT_ID>"
   ```
3. Recreate the Cloud Function instances to pick up the updated secret version:
   ```bash
   gcloud compute instances reset sre-agent --zone=us-central1-a --project="<YOUR_PROJECT_ID>"
   ```
   *(Note: The Cloud Function pulls `latest` version on start. Cloud Function instances will naturally recycle, but manually recreating or redeploying guarantees instant pickup.)*

---

## Step 3: Troubleshoot Diagnosis Failures

Diagnose the agent if the `sre_agent_health_degraded` alert fires (indicating >5 diagnosis failures in 60 minutes).

* **Owner**: SRE on-call rotation (PagerDuty: sre-primary)
* **Duration**: 10 minutes
* **Success**: Cloud Function log errors are retrieved and root cause of diagnosis failure is determined
* **Failure**: Logs cannot be retrieved or do not contain tracebacks/errors
* **Rollback**: n/a (this diagnostic step is non-mutating)
* **Escalation**: Lead SRE (@lead-sre)

### Action Steps
1. Run a gcloud command to fetch the logs from the Cloud Function:
   ```bash
   gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="sre-agent" severity>=ERROR' --project="<YOUR_PROJECT_ID>" --limit=50
   ```
2. Check for the following common root causes:
   - **Gemini API Unreachable / Authentication Error**: Check key version and quota.
   - **Firestore Permission Denied**: Check SRE Agent Service Account IAM bindings.
   - **Telegram Rate Limits / Chat Not Found**: Check chat ID configuration and token.

## Which events reach Telegram

| Agent status | Telegram message |
|---|---|
| `ok` | Full diagnosis (🚨 / 🔍 / 🛠) |
| `correlated` | Nothing, unless the signal outranks the window (`pg_fatal > mem > cpu > external_unreachable > n8n_error`): then one short **⚠️ Severity escalation** note per new top priority |
| `suppressed:bootstrap_grace`, `suppressed:live_migration` | Nothing by default. Set `sre_notify_suppressed = true` (env `NOTIFY_SUPPRESSED`) to get a brief "Подавлено: …" note |
| `closed` | Nothing — resolved notifications from Cloud Monitoring are skipped |
| `duplicate`, `bad_payload`, `disabled` | Nothing |

## Nightly snooze

`schedule-vm-stop.yml` snoozes alert policies by their `nightly_snooze`
user label (see `terraform/monitoring.tf`), not by hardcoded IDs:

* `fast` — symptom alerts (uptime, latency, MIG replacement, deep healthcheck,
  CPU, Postgres FATAL, n8n errors). `schedule-vm-start.yml` ends the snooze
  10 min after n8n is healthy.
* `slo` — burn-rate alerts. Their 1h / 6h windows still contain the night's
  failed probes, so the snooze ends 6h10m after n8n is healthy.

`startup_critical`, `log_ingestion_absent`, OOM and the agent health alert are
never snoozed. To snooze a new policy at night, give it
`nightly_snooze = "fast"` (or `"slo"`) in `user_labels`.
