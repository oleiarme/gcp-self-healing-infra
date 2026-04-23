# Terraform state bucket bootstrap

One-shot module that creates the GCS bucket used as the remote backend
for the main stack (`terraform/`). Run **once per project** before the
main stack's first `terraform init`.

## Why this is a separate module

The main stack declares `backend "gcs" {}` in `main.tf`. That block is
evaluated during `terraform init`, **before any resource can be
planned**. So the bucket cannot be a resource in the same stack.

This module solves that chicken-and-egg with two properties:

1. **Local state.** `terraform.tfstate` lives on disk here, not in GCS.
2. **Single resource.** Only `google_storage_bucket.tfstate` — no APIs
   to enable, no project to create. Keeping it minimal avoids the
   "bootstrap needs its own bootstrap" problem.

## Usage

```bash
cd terraform/bootstrap
terraform init
terraform apply \
  -var project_id=${YOUR_PROJECT} \
  -var bucket_name=${YOUR_PROJECT}-tfstate
```

Typical convention: `bucket_name = "<project>-tfstate"`. The name must
be globally unique across all of GCS.

After apply, the main stack points its backend at this bucket:

```bash
cd ../        # back to terraform/
terraform init \
  -backend-config="bucket=${YOUR_PROJECT}-tfstate" \
  -backend-config="prefix=terraform/state"
```

## What you get

- Versioning **on**. Every state overwrite keeps the superseded object
  as a non-current version. Recovery from a bad apply is a
  `gsutil cp -v <generation>` one-liner — see Runbook §5.2.
- Lifecycle rule: non-current versions deleted after 90 days
  (configurable via `var.versioning_noncurrent_retention_days`). Live
  state is never aged out.
- `uniform_bucket_level_access = true`, `public_access_prevention = "enforced"`.
  No object-level ACLs; no `allUsers`/`allAuthenticatedUsers` bindings
  possible.
- `prevent_destroy = true` on the bucket. `terraform destroy` in this
  module will refuse until you explicitly relax the lifecycle block in
  a code change.

## What this module deliberately does NOT do

- Create the GCP project.
- Enable APIs (Cloud SQL, Compute, etc — those live in the main stack).
- Provision the Workload Identity Federation pool or CI/CD service
  account (out of scope; separate concern).
- Push the main stack's state into the bucket (that happens
  automatically on the main stack's first `terraform apply`).

## Destroying

In the extremely rare case you need to remove the bucket:

1. Migrate or export the main stack's state out of the bucket.
2. Comment out the `lifecycle { prevent_destroy = true }` block in
   `main.tf` and commit the change to a PR.
3. `terraform apply` to propagate the lifecycle change.
4. `terraform destroy`.

Don't skip steps 1–2: losing the state bucket mid-apply is a
catastrophic outage — Terraform loses track of every resource it ever
created and the next plan would look like "create everything from
scratch" despite the real resources still existing.
