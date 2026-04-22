#!/usr/bin/env bash
# =============================================================================
# VM Kill Drill — synthetic MTTR measurement for the n8n MIG
# =============================================================================
# Phase 6 (chaos engineering) of docs/slo-roadmap.md.
#
# Purpose
#   The Runbook and README claim that a destroyed VM is replaced within
#   ~5-17 minutes by the regional MIG's autohealing policy, and that the
#   external uptime check recovers within the same window. Claims without
#   measurement decay; this drill forces the scenario on demand and writes
#   a markdown row you can paste into README §Reliability Evidence.
#
# What it does
#   0. Records the baseline: current MIG instance name, uptime-check state.
#   1. `gcloud compute instances delete` on the current VM — triggers the
#      MIG's "instance missing" repair path.
#   2. Polls every 15s for:
#        - a new instance showing up in the MIG (t_replacement)
#        - /healthz from the external probe returning 2xx (t_external_ok)
#   3. Prints MTTR breakdown and a markdown table row.
#
# What it does NOT do
#   * Modify any Terraform state. The MIG recreates the VM from the
#     existing instance template; no `terraform apply` runs.
#   * Kill the Cloud SQL backend or the Cloudflare tunnel. This is a VM-
#     level drill only; data-plane chaos is a separate procedure.
#   * Clean up if interrupted. The MIG will still recreate the VM on its
#     own schedule; worst case you wait ~20 minutes without the drill's
#     output. Safe to rerun.
#
# Prerequisites
#   * gcloud authenticated to the target project (gcloud auth
#     application-default login or a service account with
#     roles/compute.instanceAdmin.v1).
#   * curl for the external SLI probe.
#   * jq for parsing gcloud JSON output.
#   * The MIG must have target_size = 1 (enforced by Free Tier).
#
# Usage
#   export PROJECT_ID=my-project REGION=us-central1 MIG_NAME=n8n-mig \
#          EXTERNAL_URL=https://n8n.example.com/healthz
#   ./docs/drills/vm-kill-drill.sh
#
# Exit codes
#   0 — drill completed AND both MTTRs are within TARGET_MTTR_SECONDS.
#   1 — prerequisite check failed (missing env / CLI / MIG not found).
#   2 — MIG never produced a replacement VM within MAX_WAIT_SECONDS.
#   3 — replacement VM created but external probe never returned 2xx
#       within MAX_WAIT_SECONDS.
#   4 — drill completed but at least one MTTR exceeded TARGET_MTTR_SECONDS
#       (recovery worked, but outside the budget the README/Runbook claim).
#       The markdown row is still emitted with Result=FAIL so the
#       regression shows up in README §Reliability Evidence.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Config (env overrides)
# -----------------------------------------------------------------------------
: "${PROJECT_ID:?PROJECT_ID not set}"
: "${REGION:=us-central1}"
: "${MIG_NAME:=n8n-mig}"
: "${EXTERNAL_URL:?EXTERNAL_URL not set (e.g. https://n8n.example.com/healthz)}"
: "${MAX_WAIT_SECONDS:=1500}"   # 25 min — one std. dev. above docs-claimed worst case
: "${POLL_INTERVAL_SECONDS:=15}"
: "${TARGET_MTTR_SECONDS:=1020}"  # Must stay in sync with the ~17 min worst case in README §Resilience / Runbook §1.

log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

fail() {
    # Log only the first arg; $2 (optional) is the exit code and must
    # never leak into the human-readable message.
    log "FAIL: $1"
    exit "${2:-1}"
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
command -v gcloud >/dev/null || fail "gcloud not on PATH"
command -v jq     >/dev/null || fail "jq not on PATH"
command -v curl   >/dev/null || fail "curl not on PATH"

log "Preflight: project=${PROJECT_ID} region=${REGION} mig=${MIG_NAME}"

MIG_JSON=$(gcloud compute instance-groups managed describe "${MIG_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format=json 2>/dev/null || true)
if [ -z "${MIG_JSON}" ]; then
    fail "MIG ${MIG_NAME} not found in region ${REGION}"
fi

TARGET_SIZE=$(echo "${MIG_JSON}" | jq -r '.targetSize')
if [ "${TARGET_SIZE}" != "1" ]; then
    fail "MIG target_size=${TARGET_SIZE}; drill assumes target_size=1 (Free Tier). Adjust the script before running against HA topology."
fi

# -----------------------------------------------------------------------------
# Step 0 — Baseline
# -----------------------------------------------------------------------------
log "Step 0: record baseline"

BASELINE_INSTANCE=$(gcloud compute instance-groups managed list-instances "${MIG_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format='value(instance)' | head -1)
if [ -z "${BASELINE_INSTANCE}" ]; then
    fail "MIG has no current instance — state is already broken, don't start the drill"
fi
BASELINE_NAME=$(basename "${BASELINE_INSTANCE}")
BASELINE_ZONE=$(echo "${BASELINE_INSTANCE}" | awk -F/ '{for (i=1;i<=NF;i++) if ($i=="zones") print $(i+1)}')

log "  baseline instance: ${BASELINE_NAME} (zone=${BASELINE_ZONE})"

EXTERNAL_PRE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${EXTERNAL_URL}" || echo "000")
log "  baseline external probe: HTTP ${EXTERNAL_PRE}"
if [ "${EXTERNAL_PRE}" != "200" ]; then
    log "  WARNING: external probe is not 200 before the drill; MTTR figures will be misleading. Abort if this wasn't expected."
fi

# -----------------------------------------------------------------------------
# Step 1 — Kill
# -----------------------------------------------------------------------------
log "Step 1: delete ${BASELINE_NAME}"
T_KILL=$(date -u +%s)

gcloud compute instances delete "${BASELINE_NAME}" \
    --zone="${BASELINE_ZONE}" \
    --project="${PROJECT_ID}" \
    --quiet

log "  kill command returned t_kill=${T_KILL}"

# -----------------------------------------------------------------------------
# Step 2a — Wait for replacement VM
# -----------------------------------------------------------------------------
log "Step 2a: wait for MIG replacement"
T_REPLACEMENT=""
while [ $(($(date -u +%s) - T_KILL)) -lt "${MAX_WAIT_SECONDS}" ]; do
    CURRENT=$(gcloud compute instance-groups managed list-instances "${MIG_NAME}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format='value(instance)' 2>/dev/null | head -1 || true)
    if [ -n "${CURRENT}" ] && [ "$(basename "${CURRENT}")" != "${BASELINE_NAME}" ]; then
        T_REPLACEMENT=$(date -u +%s)
        log "  replacement: $(basename "${CURRENT}") at t+$(( T_REPLACEMENT - T_KILL ))s"
        break
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
done

if [ -z "${T_REPLACEMENT}" ]; then
    fail "No replacement VM within ${MAX_WAIT_SECONDS}s — MIG autohealing is broken" 2
fi

# -----------------------------------------------------------------------------
# Step 2b — Wait for external probe recovery
# -----------------------------------------------------------------------------
log "Step 2b: wait for external probe recovery"
T_EXTERNAL_OK=""
while [ $(($(date -u +%s) - T_KILL)) -lt "${MAX_WAIT_SECONDS}" ]; do
    CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${EXTERNAL_URL}" || echo "000")
    if [ "${CODE}" = "200" ]; then
        T_EXTERNAL_OK=$(date -u +%s)
        log "  external probe 200 at t+$(( T_EXTERNAL_OK - T_KILL ))s"
        break
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
done

if [ -z "${T_EXTERNAL_OK}" ]; then
    fail "Replacement VM created but external probe never returned 200 within ${MAX_WAIT_SECONDS}s" 3
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
MTTR_REPLACEMENT=$(( T_REPLACEMENT - T_KILL ))
MTTR_EXTERNAL=$(( T_EXTERNAL_OK - T_KILL ))
RUN_DATE=$(date -u +%Y-%m-%d)

# Compare both MTTR values against the declared target. Either
# signal breaching the budget fails the drill — the whole point is
# to catch regressions, not just outright breakage. `docs/drills/
# README.md` §Pass criteria states that partial passes are failures
# and trigger a post-mortem.
if [ "${MTTR_REPLACEMENT}" -le "${TARGET_MTTR_SECONDS}" ] \
   && [ "${MTTR_EXTERNAL}"    -le "${TARGET_MTTR_SECONDS}" ]; then
    RESULT="PASS"
    FINAL_EXIT=0
else
    RESULT="FAIL"
    FINAL_EXIT=4
fi

cat <<EOF

======================================================================
  DRILL COMPLETE
======================================================================
  date (UTC):                 ${RUN_DATE}
  baseline instance:          ${BASELINE_NAME}
  MTTR (MIG replacement):     ${MTTR_REPLACEMENT}s
  MTTR (external /healthz):   ${MTTR_EXTERNAL}s
  target from README/Runbook: <=${TARGET_MTTR_SECONDS}s (~17 min worst case)
  result:                     ${RESULT}

  Markdown row for README §Reliability Evidence:

| ${RUN_DATE} | VM kill (regional MIG) | ${MTTR_REPLACEMENT}s VM / ${MTTR_EXTERNAL}s external | ${RESULT} |

======================================================================
EOF

exit "${FINAL_EXIT}"
