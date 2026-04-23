# Post-Mortem: <incident short title>

> **Trigger matrix:** a post-mortem is required within 48h for any P1,
> whenever the 28d error budget is consumed beyond 50 %, if the MIG
> recreates the VM more than 3× in a month, or on any repeat of the same
> root cause within 30 days. See `Runbook.md` §6.3 for the full matrix.
>
> Blameless by convention — we describe what the system did, not who made
> a mistake. Hindsight wording ("should have known") is out.

## Metadata

| Field | Value |
|---|---|
| Incident ID | YYYY-MM-DD-<slug> |
| Severity | P1 / P2 / P3 |
| Status | DRAFT / IN REVIEW / FINAL |
| Author | @github-handle |
| Incident commander | @github-handle |
| Started (UTC) | YYYY-MM-DDTHH:MM:SSZ |
| Detected (UTC) | YYYY-MM-DDTHH:MM:SSZ |
| Mitigated (UTC) | YYYY-MM-DDTHH:MM:SSZ |
| Resolved (UTC) | YYYY-MM-DDTHH:MM:SSZ |
| MTTD (detect − start) | HH:MM |
| MTTM (mitigate − detect) | HH:MM |
| MTTR (resolve − start) | HH:MM |
| SLO budget consumed | X.Y % of 28d |

## 1. Summary

One paragraph. What broke, for whom, for how long, and how we got out.
If someone reads only this section they should come away with the
incident's shape.

## 2. Impact

- **User-facing impact:** external uptime-check success ratio, user
  reports, any traffic numbers.
- **Error budget:** delta consumed of the 28d availability budget
  (3.6h/month at 99.5 %). Link to the burn-rate alert that fired.
- **Data impact:** any rows affected / restored / lost. If none, say "no
  data impact".
- **Cost impact:** any surprise billing consequence (e.g. egress spike,
  emergency scale-up). Link to budget alert if it fired.

## 3. Timeline (UTC)

Bullet list, newest at bottom. Each entry links to the evidence
(dashboard URL, log query, PR, gcloud command output, Slack message).

- `HH:MM` — ...
- `HH:MM` — SLO fast-burn alert fires → on-call acks via PagerDuty.
- `HH:MM` — on-call runs `gcloud compute instance-groups managed
  list-instance-events …` → observes 2× MIG recreations in previous 10
  minutes (evidence: [link]).
- `HH:MM` — ...
- `HH:MM` — uptime check returns green consistently → mitigated.
- `HH:MM` — post-mortem triggered.

## 4. Root cause

A linked chain of causation, not a single line. "X caused Y caused Z."
Cite specific commits, config changes, or external events. If you don't
yet know the root cause, say "root cause not yet identified, investigation
continues" and keep the document in DRAFT until you do.

## 5. What went well

Things that reduced blast radius or sped up recovery. These go first so
we keep doing them.

## 6. What went wrong

Things that made the incident worse, took longer to resolve, or would
have been avoidable with better tooling / process. Not people.

## 7. Where we got lucky

Events that could have made the incident much worse but didn't. These are
usually the most valuable signal — they tell us where to invest in
resilience before the next incident.

## 8. Action items

Each action item has: description, owner (GitHub handle), severity (P1 /
P2 / P3), issue link, target date. No "TBD". No "investigate …" —
investigation is not an action item, a concrete follow-up is.

| # | Description | Owner | Severity | Issue | Due |
|---|---|---|---|---|---|
| 1 | e.g. "Add cloudflared /ready healthcheck to docker-compose" | @foo | P2 | #123 | YYYY-MM-DD |
| 2 | | | | | |

## 9. Lessons

Two to five bullets the reader can internalise without reading the rest
of the document. These feed the next hiring committee / SRE review
cycle.

## Appendix

- **Alert links:** [fast burn policy], [slow burn policy], [startup_critical policy]
- **Dashboards:** [n8n SLO dashboard]
- **Related incidents / PRs:** (if this incident recurred from a prior root cause, link the previous post-mortem)
- **Queries used:**
  ```
  (paste the gcloud / Cloud Logging / MQL queries that gave the best signal)
  ```
