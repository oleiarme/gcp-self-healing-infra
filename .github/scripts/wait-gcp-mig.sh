#!/usr/bin/env bash
# Wait for all instances in a GCP Managed Instance Group to reach RUNNING / NONE.
# Usage: wait-gcp-mig.sh --name MIG_NAME --region REGION --project PROJECT [--timeout 900]
# Exit codes: 0=ready, 1=timeout, 2=bad args
set -euo pipefail

# Defaults
TIMEOUT=900
POLL_INTERVAL=30
VERBOSE=false

usage() {
  echo "Usage: $0 --name NAME --region REGION --project PROJECT [--timeout SECS] [--verbose]" >&2
  exit 2
}

# Dependency checks
command -v gcloud >/dev/null 2>&1 || {
  echo "::error::gcloud not found in PATH"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    MIG_NAME="$2";   shift 2 ;;
    --region)  REGION="$2";     shift 2 ;;
    --project) PROJECT="$2";    shift 2 ;;
    --timeout) TIMEOUT="$2";    shift 2 ;;
    --verbose) VERBOSE=true;    shift   ;;
    *) usage ;;
  esac
done

if [ -z "${MIG_NAME:-}" ] || [ -z "${REGION:-}" ] || [ -z "${PROJECT:-}" ]; then
  usage
fi

# Verify active auth
gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q . || {
  echo "::error::No active gcloud auth"
  exit 1
}

START_TS=$(date +%s)
ATTEMPT=0

echo "Waiting for MIG '$MIG_NAME' instances to reach RUNNING / NONE (timeout: ${TIMEOUT}s) ..."

while true; do
  ATTEMPT=$((ATTEMPT + 1))
  ELAPSED=$(( $(date +%s) - START_TS ))

  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::MIG '$MIG_NAME' did not reach RUNNING/NONE after ${ATTEMPT} attempts (${ELAPSED}s)"
    exit 1
  fi

  STATUSES=$(gcloud compute instance-groups managed list-instances "$MIG_NAME" \
    --region="$REGION" \
    --project="$PROJECT" \
    --format="value(instanceStatus,currentAction)" 2>/dev/null || true)

  # Log instance table periodically or in verbose mode
  if [ "$VERBOSE" = true ] || [ "$((ATTEMPT % 5))" -eq 1 ]; then
    gcloud compute instance-groups managed list-instances "$MIG_NAME" \
      --region="$REGION" \
      --project="$PROJECT" \
      --format="table(instance,instanceStatus,currentAction)" 2>/dev/null || true
  fi

  # No instances yet
  if [ -z "$STATUSES" ]; then
    echo "Attempt $ATTEMPT (${ELAPSED}s) — no instances yet, waiting 10s..."
    sleep 10
    continue
  fi

  # All instances must be RUNNING NONE
  CLEAN=$(echo "$STATUSES" | awk 'NF')
  MATCH_COUNT=$(echo "$CLEAN" | grep -cE '^RUNNING[[:space:]]+NONE$' || true)
  TOTAL_COUNT=$(echo "$CLEAN" | wc -l | tr -d ' ')

  if [ "$MATCH_COUNT" -gt 0 ] && [ "$MATCH_COUNT" -eq "$TOTAL_COUNT" ]; then
    echo "::notice::All MIG instances RUNNING, action NONE ($MATCH_COUNT/$TOTAL_COUNT) after ${ELAPSED}s"
    exit 0
  fi

  echo "Attempt $ATTEMPT (${ELAPSED}s) — $MATCH_COUNT/$TOTAL_COUNT ready, waiting ${POLL_INTERVAL}s..."
  sleep $((POLL_INTERVAL + RANDOM % 5))
done