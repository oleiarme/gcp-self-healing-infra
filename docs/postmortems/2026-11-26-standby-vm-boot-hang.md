# Post-Mortem: stopped VM updated by deploy, boot disk hangs at "Waiting for root device"

## Metadata

| Field | Value |
|---|---|
| Incident ID | 2026-11-26-standby-vm-boot-hang |
| Severity | P2 (n8n down in working hours, no data impact) |
| Status | FINAL |
| Author | @oleiarme (drafted with Claude Code) |
| Incident commander | @oleiarme |
| Started (UTC) | 2026-11-26T09:28:02Z (VM stopped mid first boot; n8n expected up at 09:00 Lisbon = 09:00 UTC) |
| Detected (UTC) | 2026-11-26T10:09Z (serial console shows the hang) |
| Mitigated (UTC) | 2026-11-26T10:35:12Z (`/healthz` 200 after `recreate-instances`) |
| Resolved (UTC) | 2026-11-26T11:23Z (fixes #128, #130, #129 deployed; VM healthy on the final template) |
| MTTD | ~00:41 from start; ~00:10 from the first failed start (09:59) |
| MTTM | 00:26 |
| MTTR | ~01:55 |
| SLO budget consumed | not measured (VM is planned-down at night and alerts were snoozed until the end of the window) |

## 1. Summary

A docs-only push (#127) ran `deploy.yml`. Terraform resolved the COS image by family (`cos-stable`), picked up a new build, and replaced the instance template. The VM was stopped in the MIG standby pool at the time. The MIG applied the new template to the stopped VM: it created a new boot disk, started the VM and stopped it again about 2.5 minutes later, in the middle of the COS first boot. Every later boot of that disk hung in the kernel at `Waiting for root device /dev/dm-0`. n8n stayed down until the VM was recreated by hand at 10:19 UTC; it was healthy at 10:35 UTC. No data was lost: the n8n-data disk is a stateful disk with `delete_rule = NEVER`.

## 2. Impact

- **User-facing impact:** n8n (`https://<host>/healthz`) unavailable from the planned 09:00 start until 10:35 UTC (~1 h 35 min of working time). Cloudflare answered 530.
- **Error budget:** not measured for this window (nightly snoozes active, see §6).
- **Data impact:** no data impact. Postgres data lives on the stateful `n8n-data` disk, which was never detached or deleted.
- **Cost impact:** none. November bill for the project is $0.00 after the Free Tier discount.

## 3. Timeline (UTC)

- `2026-11-25 17:50–22:25` — standby pool introduced (#124), follow-ups #125, #126. Manual Stop → Start tests: VM healthy in 3.5–4.5 min.
- `2026-11-26 01:08` — `compute.instances.repair.recreateInstance` on n8n-1szm (auto-heal; cause not investigated, see action items).
- `03:23` — scheduled Stop VM: `stop-instances` → VM TERMINATED in the standby pool.
- `09:22:55` — #127 merged (drill script only). Deploy run `45791438430` starts.
- `09:23` — plan: `data.google_compute_image.cos` (family `cos-stable`) resolves `cos-stable-121-18867-652-94` (template had `…-652-79`) → `google_compute_instance_template.tpl must be replaced`.
- `09:25:05` — MIG `start` on the stopped VM; `09:25:20` new boot disk `n8n-1szm` created from 652-94.
- `09:26:03` — Docker restarts postgres (`restart: on-failure`) before cloud-init mounts the data disk (cloud-init starts 09:26:06): initdb on the unmounted mount point, "No space left on device" (found by the parallel analysis that produced #129).
- `09:27:55` — MIG `instances.update` (RESTART); `09:28:02` — MIG `stop`. The COS first boot is cut off after ~2.5 min.
- `09:40` — VM still TERMINATED; the GitHub "Start VM" cron has not run (it fired only ~2 times a day for this repo).
- `09:59:50` — manual start: PATCH `targetSize=1, targetStoppedSize=0` (test of the future Cloud Scheduler start). Same instance starts, MIG `VERIFYING`, `/healthz` 530.
- `10:09` — serial console: `device-mapper: table: 253:0: verity: Data device lookup failed (-ENODEV)`, `Waiting for root device /dev/dm-0...`, `GPT: Alternate GPT header not at the end of the disk`. Detected.
- `10:12` — `gcloud compute instances reset` → same hang.
- `10:19` — `gcloud compute instance-groups managed recreate-instances n8n-mig --instances=n8n-1szm` → new boot disk, cold start.
- `10:35:12` — `/healthz` 200. Mitigated.
- `10:37` — #128 merged (Cloud Scheduler start at 08:30 Lisbon).
- `10:51` — #130 merged (COS image pinned, deploy guard, Stop VM guard). Deploy `45805251813` (approved 10:55): `4 to add, 0 to change`, guard logs "Instance template unchanged".
- `11:00:45` — manual run of `n8n-vm-morning-start`: HTTP 200, no change to a running VM.
- `11:04` — #129 merged (postgres `restart: "no"`). Deploy replaces the template with the VM RUNNING; guard logs "No stopped VM — the MIG recreates the running VM as usual". Cold boot 11:10–11:23, `/healthz` 200. Resolved.

## 4. Root cause

1. **Unplanned template change.** `data "google_compute_image" "cos" { family = "cos-stable" }` resolved at every plan. When Google published a new COS build, any apply — including a docs-only commit — replaced the instance template.
2. **Template update on a stopped VM.** With `standby_policy MANUAL` and `update_policy PROACTIVE`, the MIG updated the STOPPED instance: start, recreate the boot disk, update (RESTART), stop again to restore the standby state — about 3 minutes in total.
3. **Stop during COS first boot.** The stop came ~2.5 minutes into the first boot of a fresh COS disk (GPT not yet grown to the full disk). The disk was left in a state the kernel could not boot from: the root partition referenced on the kernel command line (`PARTUUID=4C40906A-…`) was not found. *The exact mechanism of the disk damage is a hypothesis; the sequence start → stop mid first boot → permanent hang is confirmed by the operations log and the serial console.*
4. **Contributing — boot race.** `restart: on-failure` let Docker start postgres before `startup_cos.sh` mounted the data disk (#129).
5. **Contributing — late detection.** The morning start depended on GitHub cron, which ran ~2 times a day, so nobody expected the VM up at 09:00 and nothing alerted while the nightly snooze was active.

## 5. What went well

- The stateful data disk (`delete_rule = NEVER`) kept all n8n data through boot-disk replacement, reset and recreate.
- The serial console gave the decisive evidence (kernel log) within minutes.
- `compute operations list` gave a precise timeline of what the MIG did to the instance.
- `recreate-instances` restored service in one command (cold start, 16 min).

## 6. What went wrong

- A docs-only deploy could change the OS image of production.
- Nothing prevented the MIG from updating a stopped VM, and nothing stopped it from stopping a VM mid first boot.
- The morning start ran hours late, so the outage was found only when the start was tested by hand.
- `reset` was tried first and cost ~7 minutes; a broken boot disk needs `recreate-instances`.

## 7. Where we got lucky

- The incident happened in the morning while the system was being worked on; otherwise the VM would have stayed down until the next GitHub start run in the afternoon and the auto-heal (initial delay 2400 s) of that run.
- The template change came from a COS release, not from a change in `startup_cos.sh`, so the fix did not have to be rushed through a broken boot path.

## 8. Action items

| # | Description | Owner | Severity | Issue | Due |
|---|---|---|---|---|---|
| 1 | Start the VM at 08:30 Lisbon with Cloud Scheduler (PATCH `targetSize=1, targetStoppedSize=0`) instead of GitHub cron | @oleiarme | P2 | #128 (done) | 2026-11-26 |
| 2 | Pin the COS image by name (`var.cos_image`); deploy starts a stopped VM before a template change and stops it again only after `/healthz` 200 (19:00–07:59 Lisbon); scheduled Stop VM skips a VM < 40 min old or with a MIG action in progress | @oleiarme | P1 | #130 (done) | 2026-11-26 |
| 3 | postgres `restart: "no"` so Docker cannot start it before the data disk is mounted | @oleiarme | P2 | #129 (done) | 2026-11-26 |
| 4 | Exercise the guarded path (template change while the VM is stopped) on the next deliberate `cos_image` bump, at night, and record the result here | @oleiarme | P3 | — | next COS bump |
| 5 | Find the cause of the auto-heal recreate at 2026-11-26 01:08 UTC | @oleiarme | P3 | — | 2026-12-10 |
| 6 | Decide a COS bump cadence (security fixes now need a manual `cos_image` change) | @oleiarme | P3 | — | 2026-12-31 |

## 9. Lessons

- Anything resolved "latest" at plan time (image family, tags) turns an unrelated deploy into an OS change. Pin it.
- A stopped MIG VM is not frozen: a template change makes the MIG start, update and stop it on its own schedule.
- Never stop a COS VM during its first boot; a fresh boot disk needs to finish its first boot.
- A boot disk that hangs at `Waiting for root device` is not fixed by `reset`: recreate the instance (data on the stateful disk is safe).

## Appendix

- **Related PRs:** #124 (standby pool), #125, #126, #127 (the trigger push), #128, #129, #130.
- **Runbook:** §3 Startup Timeout / Boot Loop — row "Waiting for root device /dev/dm-0".
- **Queries used:**
  ```
  gcloud compute operations list --filter="targetLink~n8n-1szm AND insertTime>2026-11-25T20:00:00Z" --sort-by=insertTime
  gcloud compute instances get-serial-port-output n8n-1szm --zone=us-central1-a | grep -E "verity|Waiting for root|GPT"
  gcloud compute disks describe n8n-1szm --zone=us-central1-a --format="value(creationTimestamp,sourceImage.basename())"
  gh run view 45791438430 --log | grep -E "must be replaced|cos-stable"
  ```
