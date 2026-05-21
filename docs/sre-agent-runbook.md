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
