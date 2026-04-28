# CI Utility Scripts

Shared scripts used by GitHub Actions workflows. Designed to be called via
`bash .github/scripts/<script>.sh` (no execute permission required).

## Scripts

### `wait-gcp-mig.sh`

Wait for all instances in a GCP Managed Instance Group to reach `RUNNING / NONE`.

```bash
# In CI (called by schedule-vm-start.yml):
bash .github/scripts/wait-gcp-mig.sh \
  --name n8n-mig \
  --region us-central1 \
  --project my-project \
  --timeout 900 \
  --verbose

# Local debugging (requires gcloud auth):
gcloud auth login
bash .github/scripts/wait-gcp-mig.sh \
  --name n8n-mig \
  --region us-central1 \
  --project idealist426118
```

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--name` | yes | — | MIG name |
| `--region` | yes | — | GCP region |
| `--project` | yes | — | GCP project ID |
| `--timeout` | no | 900 | Max wait seconds |
| `--verbose` | no | false | Log instance table every iteration |

**Exit codes:** `0` = ready, `1` = timeout / error, `2` = bad arguments.

### `wait-url.sh`

Wait for a URL to return a specific HTTP status code.

```bash
# In CI (called by schedule-vm-start.yml):
bash .github/scripts/wait-url.sh \
  --url "https://n8n.example.com/healthz" \
  --code 200 \
  --timeout 600

# Local debugging:
bash .github/scripts/wait-url.sh \
  --url "http://localhost:5678/healthz" \
  --timeout 30
```

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--url` | yes | — | URL to poll |
| `--code` | no | 200 | Expected HTTP status |
| `--timeout` | no | 600 | Max wait seconds |

**Exit codes:** `0` = healthy, `1` = timeout / error, `2` = bad arguments.

## Design Principles

- **Idempotent** — safe to re-run; no side effects on repeated calls
- **Fail-fast** — dependency and auth checks before any work; clear exit codes
- **Observable** — elapsed time, attempt count, and instance state in every log line
- **Safe defaults** — timeouts prevent infinite loops; jitter prevents thundering herd

## Dependencies

- `wait-gcp-mig.sh`: `gcloud` (authenticated), `awk`, `grep`
- `wait-url.sh`: `curl`