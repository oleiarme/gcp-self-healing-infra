# Error Budget Policy

> SLO: **99.5 % uptime over a 28-day rolling window**, measured by the
> external `google_monitoring_uptime_check_config.n8n` probe against
> `https://<n8n_public_host>/healthz`. Error budget is therefore **0.5 %
> of 28d = ~3.36 hours** of permitted unavailability per window.
>
> This policy defines what happens as that budget is consumed. It is
> operational — the number itself is the source of truth, not the owner's
> opinion.

## Why

Without a policy, every incident prompts a subjective "should we ship
this week?" argument. An error-budget policy converts that into a rule:
**we ship as long as the budget is healthy, and we stop shipping when
it is not.** The tradeoff is agreed in advance by the team, not by the
on-call who happens to be awake at 03:00.

This is the Google SRE Workbook "Embracing Risk" pattern, scaled down to
a one-VM Free-Tier deployment.

## Budget states

Consumption is always measured over the trailing 28 days, matching the
burn-rate alerts defined in `terraform/monitoring.tf`.

| State | Budget consumed | Alert source | Required response |
|---|---:|---|---|
| Healthy | 0–25 % | none | normal shipping cadence |
| Cautionary | 25–50 % | slow-burn alert (6× rate) fires if still accelerating | Weekly error-budget review added to on-call sync; every release PR requires an explicit reliability-impact note in its body |
| Tight | 50–90 % | slow-burn alert has fired at least once | Freeze all non-reliability / non-security deploys; the deploy workflow's `environment: production` reviewer must not approve a non-P0 change. Reliability fixes and security patches remain eligible |
| Exhausted | ≥ 90 % | fast-burn alert (14.4× rate) has fired | Full freeze — only fix-forward changes for the active incident. Lift only when budget recovers ≥ 25 % headroom (i.e. consumption drops back to ≤ 75 %) |
| Breached | ≥ 100 % | all alerts firing | Incident commander declared; post-mortem required; freeze remains until post-mortem action items for mitigations land in production |

## How the freeze is enforced

The freeze is **procedural, not mechanical**. `.github/workflows/deploy.yml`
runs under the `production` GitHub Environment, which requires a human
reviewer. The policy tells that reviewer to refuse approval when the
project is in a Tight / Exhausted / Breached state.

This is deliberately low-tech:

- A mechanical enforcement (e.g. a GitHub Action that auto-fails the
  deploy when a label is set) would solve the same problem, but it
  centralises a source-of-truth decision ("are we over budget?") in a
  place that must stay in sync with Cloud Monitoring. Humans reading the
  burn-rate dashboard don't drift.
- The `production` Environment approval already exists (see Phase 3 of
  [`docs/slo-roadmap.md`](slo-roadmap.md)). This policy repurposes it
  rather than adding a second gate.

### Reviewer checklist before approving a deploy

1. Open the Cloud Monitoring dashboard published by Terraform
   (`google_monitoring_dashboard.n8n_slo`, output `dashboard_id`). Read
   the current 28-day uptime percentage.
2. Compute `budget_consumed = (99.5 - current_uptime_pct) / 0.5 * 100 %`.
   > e.g. 99.3 % uptime → consumed 40 % → Cautionary.
3. Match to the table above. If the state is Tight or worse, refuse
   approval unless:
   - the change is an explicit reliability / security fix-forward, AND
   - there is a written line in the PR description naming which action
     item, security advisory, or incident it addresses.

## How to exit a freeze

- **Tight → Cautionary:** burn-rate alert has auto-closed AND budget
  consumption is back below 50 %. No formal unfreeze step — the next
  reviewer simply sees a healthy state.
- **Exhausted / Breached → Tight or better:** incident commander posts
  an explicit "freeze lifted" note in the team channel once:
  - the uptime-check success ratio has been ≥ 99.5 % for 24 consecutive
    hours, AND
  - all mitigation action items from the incident post-mortem that are
    marked P1 are merged to `main`.

## Exceptions

- **Security patches** always ship regardless of state. They are
  themselves reliability work.
- **Rollbacks** always ship regardless of state.
- **Post-incident fix-forwards** always ship regardless of state, as
  long as the PR description names the incident.

All other exceptions require explicit opt-in from whoever holds the
`production` environment reviewer role that day.

## Review cadence

- The on-call reviews this file monthly during the error-budget sync.
- If the SLO target (99.5 %) or the measurement window (28 days) is
  changed, update the numbers in the table in the same PR that changes
  `terraform/monitoring.tf`. The two sources of truth should never
  diverge.
