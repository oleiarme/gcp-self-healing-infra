# Reliability drills

Phase 6 of [`docs/slo-roadmap.md`](../slo-roadmap.md). These are the
failure scenarios that we rehearse on a schedule — not the ad-hoc
incident response in [`Runbook.md`](../../Runbook.md). The distinction
is deliberate: a drill is a cheap, recoverable test you run on a
healthy system so that when the real incident arrives the on-call has
muscle memory and the Runbook's claims are backed by recent evidence.

## Cadence

| Drill | Target | Cadence |
|---|---|---|
| [`vm-kill-drill.sh`](vm-kill-drill.sh) | regional MIG autohealing on VM loss | **quarterly** (first Monday of each quarter) |
| Cloud SQL PITR restore | `Runbook §5.1` | **annual** (or after any Cloud SQL version upgrade) |
| Terraform state rollback | `Runbook §5.2` | **annual** (dry-run only; rollback executed only during real incident) |
| Secret version restore | `Runbook §5.3` | **opportunistic** — bundled with every scheduled secret rotation |

Quarterly is tight enough to catch silent regressions (e.g. a startup
script change that balloons boot time, a MIG policy drift) before the
Runbook claim gets wrong; looser than that and the drill becomes a
box-tick the first time a non-trivial change lands.

## Pass criteria

For **every** drill:

1. The system self-heals within the MTTR target declared in the
   relevant Runbook section.
2. No manual intervention is required beyond what the drill script
   itself does (the drill starts the incident; the system must finish
   it).
3. The on-call channel receives the expected alert flow, including
   paging where applicable, and the alert does *not* fire for so long
   that a human would have intervened had this been a real page.

A drill passes only if all three criteria hold. Partial passes ("VM
recovered but external probe was still down after 20 min") are
*failures* and trigger a post-mortem using
[`docs/postmortems/TEMPLATE.md`](../postmortems/TEMPLATE.md), same as
a production incident.

## What a drill run produces

Every drill script writes:

* A **markdown row** for `README §Reliability Evidence`. Paste it in
  verbatim; the table is append-only.
* A **structured log line** (stderr) per 15-second poll tick so you
  can reconstruct the timeline after the fact if it went badly.
* A **non-zero exit code** on failure, broken out by which SLI missed
  (see the header of each drill script).

What it does *not* write: anything to git, anything persistent in GCP
(no extra resources, no modified state), or any commit. The drill
result lives in the chat / PR where the operator pastes it.

## When to *not* run a drill

Skip the quarterly VM-kill drill if any of:

* An incident is open on the same service right now.
* A Terraform apply is in progress or within the last 30 minutes.
* The error budget for the current 28-day window is below 25 % remaining
  (see [`docs/error-budget-policy.md`](../error-budget-policy.md)).
  Drills burn budget; don't burn what you can't afford.

Reschedule — the next business day is fine. Don't combine a drill with
another operational change; the whole point is isolating causality.

## Adding a new drill

Keep each drill to a single bash file with a header comment in the
same format as `vm-kill-drill.sh`, fields required:

* **Purpose** — the Runbook claim being exercised.
* **What it does** — numbered step list.
* **What it does NOT do** — explicit non-scope.
* **Prerequisites** — CLI tools + permissions.
* **Usage** — env var export + invocation.
* **Exit codes** — enumerated with failure mode semantics.

The header is part of the drill: during a real incident the on-call
will grep the script's comments before they read the body.
