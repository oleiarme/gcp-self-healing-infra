<!--
Thanks for opening a PR. This template is deliberately short; the
goal is to make the *review* easy, not to fill out forms.

Leave any section empty only when it's genuinely not applicable —
prefer "N/A, because ..." over silent deletion so reviewers know
you considered it.
-->

## Summary

<!--
One paragraph: what changes, why. Link the issue / Runbook section /
SLO roadmap phase this addresses if applicable.
-->

## Risk & blast radius

<!--
Check exactly one. If in doubt, pick the higher category.

- [ ] **Green** — docs only, CI-only, or a change that cannot affect
      running production (e.g. unused Terraform variable, comment
      fixes). No plan/apply required.
- [ ] **Yellow** — terraform plan shows diff; change is reversible by
      reverting the commit and re-applying; no data migration.
- [ ] **Red** — irreversible or requires operator intervention to
      roll back (schema change, secret rotation with re-encryption,
      resource deletion that would destroy data). Pair-review required
      AND must link to a rollback plan in the PR body.
-->

## Review & Testing Checklist for Human

<!--
Scale the list to the Risk category above:
  Green  : 0-3 items
  Yellow : 1-3 items
  Red    : 3-5 items, each with an explicit verification command

Use `- [ ]` markdown syntax. Order by descending importance. Be
specific — "Review the Cloud SQL change" is useless; "Run `terraform
plan` and confirm deletion_protection does not flip off on
google_sql_database_instance.main[0]" is what a reviewer can act on.
-->

## Rollback plan

<!--
Required for Red. Optional for Yellow. Skip for Green.
Write the specific commands a human would run to revert, not a
generic "git revert". Reference Runbook §5 where applicable.
-->

### Notes

<!--
Anything else a reviewer should know: screenshots, links to related
PRs, known follow-ups, caveats. Do NOT paste session URLs or
requester info here — those are appended automatically.
-->
