#!/usr/bin/env bash
# =============================================================================
# scripts/resolve-image-refs.sh
#
# Export TF_VAR_<name> for every Terraform variable name passed as an
# argument, so the workflow steps that mirror images and the later
# `terraform plan/apply` all see the same value.
#
# Resolution order per variable:
#   1. TF_VAR_<name> already set and non-empty in the environment
#      (workflow input or GitHub repository variable) — used as an override.
#   2. The `default = "..."` of `variable "<name>"` in terraform/variables.tf.
#
# terraform/variables.tf is the single source of truth: it is the file that
# scripts/refresh-digests.sh rewrites. Workflows used to carry their own
# copies of these defaults, which silently overrode variables.tf and kept
# digest bumps from ever reaching production.
#
# Usage (from the repository root, inside a GitHub Actions step):
#   bash scripts/resolve-image-refs.sh n8n_image n8n_image_tag
#
# Exit codes:
#   0 — every variable resolved and was appended to $GITHUB_ENV
#   1 — a variable has neither an override nor a default in variables.tf
# =============================================================================

set -euo pipefail

TF_VARS_FILE="${TF_VARS_FILE:-terraform/variables.tf}"

if [[ ! -f "$TF_VARS_FILE" ]]; then
  echo "resolve-image-refs.sh: cannot find $TF_VARS_FILE from $(pwd)" >&2
  exit 1
fi

# Print the quoted default of `variable "<name>"`, or nothing if absent.
tf_default() {
  awk -v name="$1" '
    $1 == "variable" && $2 == "\"" name "\"" { in_block = 1; next }
    in_block && $1 == "default" {
      if (match($0, /"[^"]*"/)) print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
    in_block && /^}/ { exit }
  ' "$TF_VARS_FILE"
}

for name in "$@"; do
  env_name="TF_VAR_${name}"
  value="${!env_name:-}"
  source="override"

  if [[ -z "$value" ]]; then
    value="$(tf_default "$name")"
    source="$TF_VARS_FILE"
  fi

  if [[ -z "$value" ]]; then
    echo "::error::resolve-image-refs.sh: no value for ${env_name} (no override, no default in ${TF_VARS_FILE})" >&2
    exit 1
  fi

  echo "${env_name}=${value} (from ${source})"
  echo "${env_name}=${value}" >> "$GITHUB_ENV"
done
