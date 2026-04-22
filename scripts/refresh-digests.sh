#!/usr/bin/env bash
# =============================================================================
# scripts/refresh-digests.sh
#
# Resolve the current SHA256 digests for every container image whose pinned
# reference lives in terraform/variables.tf (format "<image>:<tag>@sha256:<digest>")
# and rewrite the file in-place when any digest has changed.
#
# Intended usage:
#   * Called by .github/workflows/digest-refresh.yml (weekly cron + manual
#     dispatch). The workflow then runs peter-evans/create-pull-request on
#     the working-tree diff to open a review PR with the bumped digests.
#   * Runnable locally — `crane` + `sed` + `awk` are the only runtime deps.
#     Install crane via Homebrew (`brew install crane`) or Go
#     (`go install github.com/google/go-containerregistry/cmd/crane@latest`).
#
# Exit codes:
#   0 — success; may or may not have changed the file (diff it to tell)
#   1 — upstream query failed for at least one image (treat as CI failure
#       so we notice outages / name changes instead of silently skipping)
#
# The script is idempotent: calling it twice in a row on the same tree is a
# no-op the second time.
# =============================================================================

set -euo pipefail

TF_VARS_FILE="${TF_VARS_FILE:-terraform/variables.tf}"

if [[ ! -f "$TF_VARS_FILE" ]]; then
  echo "refresh-digests.sh: cannot find $TF_VARS_FILE from $(pwd)" >&2
  exit 1
fi

if ! command -v crane >/dev/null; then
  echo "refresh-digests.sh: 'crane' not on PATH. Install via:" >&2
  echo "  go install github.com/google/go-containerregistry/cmd/crane@latest" >&2
  echo "  brew install crane" >&2
  exit 1
fi

# Matches every `default = "<registry>/<repo>:<tag>@sha256:<hex64>"` line in
# variables.tf. The regex is intentionally narrow so we never rewrite an
# unrelated string by accident.
IMAGE_LINE_RE='default[[:space:]]*=[[:space:]]*"[^"@]+:[^"@]+@sha256:[0-9a-f]{64}"'

changed=0
failed=0

# Collect every "default = <image_ref>" occurrence.
while IFS= read -r line; do
  current_ref="$(echo "$line" | sed -E 's/^.*default[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')"
  image_with_tag="${current_ref%@*}" # strip "@sha256:..."
  current_digest="${current_ref#*@}" # "sha256:..."

  echo "→ resolving $image_with_tag (currently pinned to $current_digest)"

  if ! new_digest="$(crane digest "$image_with_tag" 2>/dev/null)"; then
    echo "  ✗ crane digest failed for $image_with_tag" >&2
    failed=1
    continue
  fi

  if [[ "$new_digest" == "$current_digest" ]]; then
    echo "  = already up to date"
    continue
  fi

  new_ref="${image_with_tag}@${new_digest}"
  echo "  ↑ bump: $current_digest → $new_digest"

  # Escape slashes for sed.
  esc_current="$(printf '%s\n' "$current_ref" | sed 's/[\/&]/\\&/g')"
  esc_new="$(printf '%s\n' "$new_ref" | sed 's/[\/&]/\\&/g')"
  sed -i "s/${esc_current}/${esc_new}/g" "$TF_VARS_FILE"
  changed=1

done < <(grep -E "$IMAGE_LINE_RE" "$TF_VARS_FILE")

if (( failed )); then
  exit 1
fi

if (( changed )); then
  echo "refresh-digests.sh: $TF_VARS_FILE updated"
else
  echo "refresh-digests.sh: no changes"
fi
exit 0
