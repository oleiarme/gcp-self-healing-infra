# On-Call Rotation

> This file is the canonical source for who gets paged when. Cloud
> Monitoring notification channels (email, Slack — see
> `terraform/monitoring.tf`) deliver to the rotation; this file defines
> the rotation itself.
>
> Single-service Free-Tier deployment — the rotation is intentionally
> flat (primary + backup, one week each). There is no secondary pager or
> follow-the-sun tier.

## Roster

| Role | Member | GitHub | Timezone | Notes |
|---|---|---|---|---|
| Primary | TBD | @tbd | UTC+? | Owns P1/P2 acks |
| Backup | TBD | @tbd | UTC+? | Takes the pager on primary sick day / vacation |
| Escalation | TBD (eng manager) | @tbd | UTC+? | Called if primary + backup both miss 2× ack SLA |

> Update this table in-place whenever the rotation changes. Commits to
> this file do not require running Terraform; they only affect human
> process.

## Rotation schedule

| Week start (Monday, UTC) | Primary | Backup |
|---|---|---|
| 2026-W01 | @tbd            | TBD |
| 2026-W02 | @tbd            | TBD |
| …        | …                | …    |

Rotation cadence: **one week**, Monday 00:00 UTC → next Monday 00:00
UTC. Hand-off is async (Slack message in `#n8n-ops` confirming the
primary has read the runbook and has `gcloud` configured on their
workstation).

## SLAs

| Severity | Signal | Ack SLA | Resolve SLA | Channel |
|---|---|---|---|---|
| P1 | SLO fast-burn (14.4×) OR startup_critical OR log_ingestion_absent | 15 min | 2 h | PagerDuty (or primary phone if PD is not provisioned) |
| P2 | SLO slow-burn (6×) OR repeated startup_critical within 24h | 1 h | 8 h | Slack `#n8n-ops` |
| P3 | Single startup failure, one-off uptime-check blip | next business day | 72 h | GitHub issue |

Escalation policy:
- Missed ack SLA × 1 → page backup.
- Missed ack SLA × 2 → page escalation (eng manager).
- Escalation responsible for re-paging or taking manual ownership.

## Notification channels (wiring)

The corresponding Terraform-managed channels are:

- `google_monitoring_notification_channel.email` — always on, address is
  `var.oncall_email` (a team inbox, not an individual's personal email).
- `google_monitoring_notification_channel.slack` — provisioned only when
  `var.slack_auth_token` is set. Posts to `var.slack_channel` (default
  `#n8n-ops`).

Adding a per-person channel (PagerDuty, phone) is out of scope for this
repo; configure those downstream in PagerDuty itself and use the email
address of the PD service integration in `var.oncall_email`.

## Responsibilities

### Primary

- Keep the pager device on and reachable within the Ack SLA.
- Follow the procedures in `Runbook.md` when paged.
- File a post-mortem for any P1 per
  [`docs/error-budget-policy.md`](error-budget-policy.md).
- Hand off cleanly on Monday with any open action items called out.

### Backup

- Ready to take over if primary is unreachable.
- Same runbook knowledge as primary.
- On the first day of each rotation, verify their `gcloud` auth works
  against `var.project_id`.

### Escalation (eng manager)

- Makes the call on whether to declare a security or reliability
  incident.
- Approves exceptions to the error-budget freeze (see
  [`docs/error-budget-policy.md`](error-budget-policy.md) §Exceptions).
- Runs the post-mortem review meeting.

## Process diagrams

Alert → who gets paged:

```
Cloud Monitoring alert policy fires
  ↓
notification_channels = [email, slack (if var.slack_auth_token)]
  ↓
email → PagerDuty service integration (configured out-of-band)
         → primary on-call phone
         → (missed ack × 1) → backup phone
         → (missed ack × 2) → escalation phone
  ↓
slack `#n8n-ops` channel → everyone sees the alert in parallel
```
