#!/usr/bin/env bash
# Wait for a URL to return a specific HTTP status code.
# Usage: wait-url.sh --url URL [--code 200] [--timeout 600]
# Exit codes: 0=healthy, 1=timeout, 2=bad args
set -euo pipefail

# Defaults
EXPECTED_CODE=200
TIMEOUT=600
POLL_INTERVAL=20
CONNECT_TIMEOUT=3
MAX_TIME=5

usage() {
  echo "Usage: $0 --url URL [--code CODE] [--timeout SECS]" >&2
  exit 2
}

# Dependency checks
command -v curl >/dev/null 2>&1 || {
  echo "::error::curl not found in PATH"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --url)     URL="$2";           shift 2 ;;
    --code)    EXPECTED_CODE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2";       shift 2 ;;
    *) usage ;;
  esac
done

if [ -z "${URL:-}" ]; then
  usage
fi

START_TS=$(date +%s)
ATTEMPT=0

echo "::notice::Starting health check for $URL (expect HTTP $EXPECTED_CODE, timeout: ${TIMEOUT}s)"

while true; do
  ATTEMPT=$((ATTEMPT + 1))
  ELAPSED=$(( $(date +%s) - START_TS ))

  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::Health check failed after $ATTEMPT attempts (${ELAPSED}s)"
    exit 1
  fi

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    "$URL" 2>/dev/null) || true
  : "${HTTP_CODE:=000}"

  if [ "$HTTP_CODE" = "$EXPECTED_CODE" ]; then
    echo "::notice::$URL is healthy (HTTP $HTTP_CODE) after ${ELAPSED}s"
    exit 0
  fi

  if [ "$HTTP_CODE" = "000" ] || [ -z "$HTTP_CODE" ]; then
    echo "Attempt $ATTEMPT (${ELAPSED}s) — connection failed (timeout/DNS), retrying in ${POLL_INTERVAL}s..."
  else
    echo "Attempt $ATTEMPT (${ELAPSED}s) — HTTP $HTTP_CODE, retrying in ${POLL_INTERVAL}s..."
  fi

  sleep $((POLL_INTERVAL + RANDOM % 5))
done