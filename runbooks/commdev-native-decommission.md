# ComDev - AWS Native (PASP/Docker Swarm) Tenant Decommission

## When to use

- An RFC/ticket requests permanently decommissioning a **native** CommDev tenant — one running as `tenant_<code>_*` Docker Swarm services on the PASP platform (`PROD-PA-Pro` / `Pa-pro-staging`), defined in the `pasp-tenants` Terraform repo. **PASP hosts more than one application** — a tenant's tfvars block can include `comdev`/`commdev` (this runbook's scope) alongside `finance`/`utilities` (ComPLUS, a separate application) — confirm you're removing only the `comdev`/`commdev` block.
- **Does not apply to legacy CommDev/TRAKiT clients** (EC2 instances in `PALegacyCommDev`/`PALegacySharedServices`, manually launched, domain-joined to `aspgov.pri`) — use [`legacy-server-decommission.md`](legacy-server-decommission.md)'s "CommDev (TRAKiT/SSRS) — Legacy Decommission Specifics" section for those instead.

---

## Pre-checks

- [ ] Confirm which environments the tenant actually has infrastructure in — **both** `stg` and `prod`, or only one. Check the tenant tfvars files in `pasp-tenants` (see Phase 3 for exact filenames) for a block under `tenants.<code>.comdev` (or `commdev`) in each.
- [ ] Confirm the client's tenant shortcode exactly as it appears in the tfvars and in Docker service names — do not assume it matches the Salesforce/RFC client code casing (tfvars/Docker use lowercase).
- [ ] AWS SSO session active for `PROD-PA-Pro` (prod) and/or `Pa-pro-staging` (staging), SSO session `foundation`.
- [ ] Local clone of `pasp-tenants` (`https://dev.azure.com/psgov/Cloud/_git/pasp-tenants`) exists, is on a clean `master`, and is pulled to latest before editing (`git status`, `git checkout master`, `git pull`) — same posture as `/pasp-ppt-disk-expand`. If uncommitted changes exist, stop and ask rather than discarding them.
- [ ] Check whether the tenant has an attachment-migration S3 bucket/IAM user (`/commdev-attachment-migration` skill output) — search for a CloudFormation stack named `<CODE-UPPER>-CommDev-Attachment-Migration` in `legacy-Shared-Services` (343823317319), **in both us-east-1 and us-west-2** — it has been found in us-west-2 for an otherwise us-east-1 tenant, so check both regions regardless of where the tenant's app servers run. Most clients will not have one — a "no stack found" result is a normal outcome, not a failed check.
- [ ] Check whether the tenant also has a legacy web server and/or RD server — search `PALegacyCommDev` (both regions) for `<CLIENTCODE>-*TRKWB*` and `PALegacySharedServices` (both regions) for `<CLIENTCODE>-PTRKRD*`. Treat these as two independent checks — do not stop searching for one just because the other was found or not found.
- [ ] **RFC approved** before any stop/terminate/Terraform-apply/service-removal step. Backups (Phase 0) and gathering information (Phase 1) happen ahead of approval by design — the RFC itself needs the backup links. Opening the tenant-removal PR (Phase 4) can also happen ahead of approval; do not apply the Terraform change, remove Docker services, or touch anything else in Phases 5+ until approved.

---

## Procedure

### 0. Take a final, explicitly-retained backup of every instance in scope

Do this **before** filing the RFC (Phase 1) — the RFC must include each instance's recovery point link. Covers native app servers now; if Phase 0's pre-checks found a legacy web/RD server, back those up here too rather than waiting for Phase 8.

Native CommDev app servers and legacy CommDev servers are both tagged `cst_backup_policy` and covered by tag-driven AWS Backup plans — but **the vault name and IAM role differ per account, and the script's built-in defaults (`BackupVault` / `arn:aws:iam::797320052894:role/Backup-Role`) are legacy-account values that are wrong for the PASP accounts.** Always pass `-BackupVaultName`/`-IamRoleArn` explicitly — do not rely on the script's defaults outside a legacy account where they happen to already be correct.

| Account | Vault | IAM role |
|---|---|---|
| `PROD-PA-Pro` (911318933593) | `pac-prd-backup-vault-east` | `arn:aws:iam::911318933593:role/backup-plan-role` |
| `Pa-pro-staging` (553030370815) | `pac-stg-backup-vault-east` | `arn:aws:iam::553030370815:role/backup-plan-role` |
| `PALegacySharedServices` (361362055558) — legacy RD server, if any | `BackupVault` | `arn:aws:iam::361362055558:role/Backup-Role` |

Confirm these against `aws backup list-backup-vaults` / `aws backup list-backup-selections` + `get-backup-selection` for the account in question if in doubt — do not assume they're stable across future account changes.

Run one snapshot per account/environment in scope, each with its **own distinct `-TicketRef` suffix** (e.g. `<ticket>-PROD`, `<ticket>-STG`, `<ticket>-LEGACY`) — the script names its output CSV from `TicketRef` + date only, with no account/environment marker, so two runs sharing the same `-TicketRef` on the same day will silently overwrite each other's results file:

```powershell
pwsh scripts/aws/decommission/New-DecommissionSnapshot.ps1 `
    -Profile <PROD-PA-Pro|Pa-pro-staging|PALegacySharedServices> `
    -InstanceListCsv .\<ticket>-<env>-instances.csv `
    -TicketRef <ticket>-<ENV> `
    -BackupVaultName <vault-from-table-above> `
    -IamRoleArn <role-from-table-above> `
    -RetentionDays 180 `
    -WhatIf
```

Review, then re-run without `-WhatIf`. Include **every** instance found in the pre-checks — current and old/replaced app servers, plus any legacy web/RD server. Do not proceed to Phase 1 until every instance across every account/environment shows `State=COMPLETED`. Record each instance's `RecoveryPointArn` (AMI ID) and Backup Job ID from the output CSV — these go directly into the RFC.

### 1. Gather information and create the RFC

Gather and record the following, then create the Salesforce RFC with it attached. Do not file the RFC with placeholders — gather everything first, including the backup links from Phase 0.

- **Account/environment**: which of `prod` (`PROD-PA-Pro`, 911318933593) / `staging` (`Pa-pro-staging`, 553030370815) has infrastructure for this tenant.
- **Instance name and ID** for every EC2 resource tied to the tenant — this includes the current app server(s) **and any old/replaced instance from the recent EC2 migration project** (e.g. a client may have both `pac-prd-<code>-com` and a stopped `pac-prd-<code>-com-old`). Do not assume a single current instance — check for `-old`-suffixed or otherwise stale instances tagged with the client code before building the manifest.
- **Private IP address** for every instance found above. Native CommDev instances are not internet-facing — there is normally no public IP/Azure DNS record to record here (unlike legacy TRAKiT). If one is found, treat it as unexpected and confirm its purpose with the requester before proceeding.
- **Backup recovery point link/ARN and retention date** for every instance, from Phase 0 — native and legacy.
- **Docker Swarm services** — full `docker service ls | grep <code>` output from a manager node in every environment in scope (see Phase 5 for how to connect). Record this now for the RFC evidence — removal itself happens later, in Phase 5, after the Terraform apply. Actual service names vary per client/build (e.g. some clients have `rabbitmq`, `cashreceipts_*`, or `workflow_*` services and others don't) — record whatever is actually present, don't assume a fixed list.
- **Attachment bucket/IAM resources** — record the result either way (found: bucket/user/stack name and region; not found: note that explicitly, since absence is the common case).
- **Legacy web/RD server footprint**, whatever was found in the pre-checks (full pair, RD-only, web-only, or none) — hand this to Phase 8.
- **If a legacy RD server was found: check and record its DNS footprint now**, before filing the RFC — do not leave this to Phase 8. There are three separate DNS surfaces for the same hostname, check all independently (finding one does not mean the others exist):
  1. `aspgov.pri` A record on the region-appropriate DC (see `legacy-server-decommission.md`'s DC naming table — confirm the DC's actual region via `describe-instances`, don't trust the hostname pattern alone).
  2. Internal `aspgov.com` CNAME on `inf-svrdns001` (e.g. `<CLIENTCODE>-TRK-SSRS-RD` → `<clientcode>-ptrkrd001.aspgov.pri.`).
  3. External Azure DNS `aspgov.com` A record (`az network dns record-set a show --zone-name aspgov.com --resource-group Azure_DNS_RG --name <CLIENTCODE>-TRK-SSRS-RD`) — may not exist at all; a `NotFound` here is a normal, valid result, not a missed check.

Only submit the RFC once all of the above is captured.

### 2. Remove from LogicMonitor

Manual step. Do this **before** the Terraform apply and before removing any Docker service, so alerting doesn't fire on a decommission-in-progress tenant:

1. Log into the LogicMonitor portal.
2. Search for the tenant's app server(s) (by instance name) and, if monitored individually, the tenant's site/URL.
3. Delete or disable each device/website check (confirm delete vs. disable with your LM admin, same as legacy).
4. Record before/after device count for the RFC evidence.

### 3. Confirm RFC approval

Do not proceed past this point until the RFC from Phase 1 is explicitly approved — Phases 4 onward include the Terraform PR (safe pre-approval, but the *apply* is not), Docker service removal, and other changes that must not happen before approval.

### 4. Remove the tenant from Terraform (`pasp-tenants`)

**This step opens a PR only. Do not run `terraform apply`/`destroy`** — per team convention (same posture as `/pasp-ppt-disk-expand`), a human applies it locally after PR approval. **Docker services must stay running until this apply is confirmed complete** — do not jump ahead to Phase 5.

1. In the local `pasp-tenants` clone, confirm you're on a clean, up-to-date `master`.
2. **Create and switch to the decommission branch now, before editing any file:**
   ```powershell
   git checkout -b decom/<tenant-code>-commdev-<date:yyyyMMdd>
   ```
   Do not edit `prd.tfvars`/`stg.tfvars`/`CHANGELOG.md` while still on `master` — even briefly. All edits in steps 3–5 below must happen only after this checkout.
3. The tenant tfvars files are `environment_tenants/prd.tfvars` (production) and `environment_tenants/stg.tfvars` (staging) — **note the filename is `prd.tfvars`, not `prod.tfvars`.** Remove the tenant's `comdev`/`commdev` block from whichever file(s) the pre-checks found infrastructure in. **Only remove the ComDev/CommDev block for this client — do not touch a sibling `finance` or `utilities` block under the same tenant code**; those two together are the ComPLUS application, a separate product from ComDev, and are out of scope unless the RFC explicitly covers a ComPLUS decommission too.
4. **Check the same file's top-level `legacy_apis` array** (a flat list of objects near the bottom of the file, not nested under `tenants`) for any entry with `tenant = "<code>"` — these are third-party integration configs (e.g. `paymentus`, `cstpayments`, `selectron`) that are easy to miss since they're not part of the tenant's main block. Remove every matching entry, in every tfvars file where it appears, as part of the same change. Not every tenant has one of these — absence is normal.
5. Update `CHANGELOG.md` under `## [Unreleased]` (or add a new `## <MM-DD-YYYY>` heading if none exists yet for today) with a `### Removed` bullet per file touched, matching the repo's existing convention, e.g.:
   ```markdown
   ### Removed
   - `prd.tfvars` - removed <code> CommDev tenant block and legacy_apis entry (decommission, RFC <ref>)
   - `stg.tfvars` - removed <code> CommDev tenant block and legacy_apis entry (decommission, RFC <ref>)
   ```
   Do this **before** committing — it belongs in the same commit as the tfvars change, not a follow-up.
6. Commit and push:
   ```powershell
   git add environment_tenants/prd.tfvars environment_tenants/stg.tfvars CHANGELOG.md
   git commit -m "Remove <tenant-code> CommDev tenant (decommission, RFC <ref>)"
   git push -u origin decom/<tenant-code>-commdev-<date:yyyyMMdd>
   ```
7. Open the PR via `scripts\azdo\New-PRViaRest.ps1` (not `New-PR.ps1` — same reasoning as `/pasp-ppt-disk-expand`: the `az repos` extension is broken on this machine):
   ```powershell
   pwsh "$env:USERPROFILE\repos\cloudops\scripts\azdo\New-PRViaRest.ps1" `
       -Title "Remove <tenant-code> CommDev tenant (decommission)" `
       -DescriptionFile "C:\Temp\pr-<tenant-code>-commdev-decom.md" `
       -TargetBranch master
   ```
   PR description follows the team's Summary/Test plan/Blast radius structure — blast radius must state which environment(s), that merging does **not** by itself destroy infrastructure, and that Docker services for this tenant remain live and serving traffic until the apply completes.
8. After the PR is approved and merged, `terraform plan`/`apply` is run locally against each affected workspace — **staging first, then production**. Exact sequence (from `pasp-tenants/README.md`):
   ```powershell
   cd C:\Users\<user>\repos\pasp-tenants
   $env:AWS_PROFILE="Tools-prod"
   terraform init -backend-config backend.tfvars -reconfigure
   terraform workspace list
   terraform workspace select stg
   terraform workspace show
   terraform plan -out plan.tfplan -var-file environment_tenants/$(terraform workspace show).tfvars
   # when prompted for "ami", just press Enter
   terraform apply plan.tfplan
   ```
   Repeat with `terraform workspace select prd` for production, after staging's apply is confirmed complete — do not run both applies back-to-back without reviewing each plan first. **Confirm the plan output shows only this tenant's resources being destroyed before running `apply`** — if the human running this is not the same person who prepared the PR, have them share the plan's resource summary for a second look before applying.

   **If the plan shows changes to resources that don't reference this tenant** (e.g. a tag being added/removed across many unrelated tenants, or a single unrelated tenant's volume/instance size changing): stop, do not apply. This has happened twice in practice — a bulk tag rollout (`cst_schedule`) in progress on another branch/script showed up as removing that tag from ~70 unrelated resources, and a separate case where an EBS volume had been resized directly in AWS (confirmed via CloudTrail `ModifyVolume`) without the matching tfvars value being updated, so the plan tried to shrink it back (EBS volumes cannot shrink — this would fail or worse). Both are real infrastructure drift unrelated to this decommission, not something to paper over by applying anyway:
   - Identify the drift's owner (check CloudTrail for who/what last touched the affected resource) and have them land their own fix in their own PR/branch — don't let a decommission apply absorb someone else's in-flight change.
   - Do not commit a same-branch fix for someone else's drift. If you need the plan to come back clean for *this* run only, edit the affected tfvars value locally to match live reality (uncommitted, local-only), re-plan to confirm the unrelated resource drops out, apply, then leave the local edit for the other change's owner to land properly — do not push it.
   - Only proceed once the plan's resource list contains **only** resources referencing this tenant's code (module addresses, tags, or `for_each` keys) plus expected shared side-effects (see next note).

   **Expect one shared, non-tenant resource to show as changed, not destroyed:** `aws_api_gateway_stage.pasp_api_proxy_live` (and a paired `aws_api_gateway_deployment.pasp_api_proxy_live` replace) redeploys because removing this tenant's `legacy_apis` API Gateway resources changes the overall API's resource hash. This is a normal, expected side effect of Phase 4 step 3's `legacy_apis` cleanup — not drift — and only appears when the tenant being removed had a `legacy_apis` entry.

   **If `apply` errors with `waiting for EBS Volume ... Attachment ... delete: unexpected state 'busy'`:** the instance is still running and the guest OS (typically Windows) is holding a lock on the volume, so AWS can't complete a clean detach. Confirmed to happen on both staging and prod runs, resolved the same way both times:
   1. Stop the instance directly: `aws ec2 stop-instances --profile <profile> --region <region> --instance-ids <instance-id>`.
   2. Poll until it reaches `stopped` (`aws ec2 describe-instances ... --query Reservations[0].Instances[0].State.Name`) — this forces a clean unmount and the volume detaches on its own within seconds of the instance stopping.
   3. The saved plan is now stale (state changed outside Terraform) — re-run `terraform plan -out plan.tfplan -var-file environment_tenants/<env>.tfvars` fresh, confirm the remaining resource count/list looks right (should be a small number — whatever didn't finish destroying yet), then `terraform apply plan.tfplan` again.
   4. If a *different* error appears afterward — `IncorrectState: Volume '...' is in the 'available' state` on an `aws_volume_attachment` resource — Terraform's state still thinks an attachment exists that AWS already considers gone (a side effect of the manual stop). Remove it from state directly: `terraform state rm 'module.tenant_app["<tenant>_comdev"].aws_volume_attachment.<data|user>_attachment[0]'`, then re-plan and apply again as in step 3. This is safe — the resource is already gone from AWS, `state rm` just stops Terraform from trying to delete something that no longer exists.
9. Once the apply is confirmed complete, verify no EC2 instances remain for the tenant:
   ```powershell
   aws ec2 describe-instances --profile <PROD-PA-Pro|Pa-pro-staging> --region <region> `
       --filters "Name=tag:Name,Values=*<tenant-code>*" `
       --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,InstanceId:InstanceId,State:State.Name}" `
       --output table
   ```
   **Do not stop at "the current instances are terminated."** This query returns every instance matching the tenant code — read the full table. If any `-old`-suffixed (or otherwise stale/replaced) instance from Phase 1 still shows a state other than `terminated`, Terraform never knew about it (predates the current tenant module) and it will **not** be destroyed by `terraform apply`, no matter how many times you re-run it. It has been missed this way in practice (confirmed both when a `-stg` and a `-prd` `-old` instance were still sitting `stopped` after their environment's apply completed) — treat "check for `-old`" as a mandatory step here, not an edge case to remember later.
   - If a stale instance is found still `stopped`: it already has a `COMPLETED` backup from Phase 0 (re-check the manifest CSV to confirm — do not skip straight to terminate without that). Terminate it via the legacy-style script, reusing the same manifest and RFC approval:
     ```powershell
     pwsh scripts/aws/decommission/Remove-DecommissionedInstances.ps1 `
         -Profile <PROD-PA-Pro|Pa-pro-staging> `
         -BackupManifestCsv <phase-0-manifest-csv> `
         -RfcApproved `
         -WhatIf
     ```
     The script safely skips any instance in the manifest that already shows `terminated` (e.g. the ones Terraform just destroyed) and only flags the stale `-old` instance(s) as eligible — review that output, then re-run without `-WhatIf` (or with `-Force` in a non-interactive session).
   - If a stale instance is found still `running` (not `stopped`): do not terminate directly — go back to Phase 0's backup step for it if not already covered, then use `Stop-DecommissionedInstances.ps1` before `Remove-DecommissionedInstances.ps1`, same as the legacy runbook's main sequence.
   - Repeat this check for **each environment independently** — a tenant can have a stale instance in staging, prod, both, or neither; do not assume the presence/absence in one environment predicts the other.
10. **Do not proceed to Phase 5 until this apply (and the stale-instance check in step 9) is confirmed complete.** If the apply already stopped/destroyed the app server(s) that were hosting the Docker services, some services in Phase 5 may already be gone — that's expected, not an error.

### 5. Remove tenant Docker Swarm services

Only start this phase after Phase 4's Terraform apply is confirmed complete. **Do staging fully (remove + verify empty) before starting production** — same ordering convention as Phase 4's apply, so a mistake or partial failure surfaces in the lower-stakes environment first.

Connect to a manager node via SSM in the correct environment:

| Environment | AWS profile | Manager (try in order) |
|---|---|---|
| Production | `PROD-PA-Pro` (`com-prd`) | `pac-prd-ubuntu-mgr1`, then `mgr2`, then `mgr3` |
| Staging | `Pa-pro-staging` (`com-stg`) | `pac-stg-ubuntu-mgr1`, then `mgr2`, then `mgr3` |

```powershell
aws ssm start-session --target <manager-instance-id> --profile <com-prd|com-stg> --region us-east-1
```

Once connected:

```bash
sudo su -
docker service ls | grep <tenant-code>
```

Remove **every** service that matches the tenant code. **Do not rely on a fixed service-name list** — confirmed across real clients, the actual set varies: some have `rabbitmq`, `cashreceipts_rest`/`cashreceipts_service`, or `workflow_rest`/`workflow_service`/`workflow_ui` (sometimes already scaled to `0/0`), others don't; core services like `gateway`, `globalconfig_1/2/3`, `globalconfig_rest`, `commonentity_rest`, `commonentity_ui`, `comdev_navigation`, `comdev_rest` are common but not guaranteed either. Removing only an assumed subset (e.g. just the `comdev_*` pair) leaves other services consuming swarm resources and confuses the next engineer who greps for the tenant later — always work from the live `grep` output, not from memory of what a typical tenant has:

```bash
docker service rm <service-name>
```

Also check for a tenant stack (`docker stack ls`) and remove it if present. Re-run `docker service ls | grep <tenant-code>` afterward to confirm nothing remains.

> If services don't exist in an environment (e.g. tenant was staging-only), or were already removed as a side effect of the Terraform apply, this step is a no-op there — don't treat "not found" as an error.

### 6. Remove Parameter Store entries not controlled by Terraform

Some tenant parameters live outside Terraform state — in practice this is a substantial set (commonly 50+ parameters per account/environment: DB credentials, connection strings, TRAKiT/Cognos config, CCR/commonentity secrets, workspaces keyvault secrets, and more), not a handful. Clean these up in every environment the tenant had — **staging first, then production**, same ordering convention as Phases 4 and 5:

1. Search `/tenant/<tenant-code>` in Parameter Store (see [`commdev-parameter-store-access.md`](commdev-parameter-store-access.md) for console access/role).
   **If checking via AWS CLI from Git Bash on Windows**, be aware that Git Bash auto-converts a leading-slash argument like `/tenant/<code>` into a Windows path before it reaches the AWS CLI, which makes `aws ssm describe-parameters --parameter-filters ...` silently return zero results even when parameters exist — a false negative, not a real absence. Use `MSYS_NO_PATHCONV=1` as an env prefix on the command, or `aws ssm get-parameters-by-path --path "/tenant/<code>" --recursive`, and sanity-check against a known-populated tenant path if a search comes back empty before trusting that result.
2. Delete any remaining parameters. `aws ssm delete-parameters` accepts at most 10 names per call — for the typical 50-90+ parameter count per client/environment, script the batching (e.g. a small Python/PowerShell loop over the full name list in chunks of 10) rather than calling it one name at a time.
3. Confirm none remain by re-running the search (with the same Git Bash caveat in mind) — `aws ssm get-parameters-by-path --path "/tenant/<code>" --recursive --query "length(Parameters)"` should return `0`.

### 7. Remove the S3 attachment-migration bucket/IAM resources, if any

**Most clients will not have one of these** — this is a check-then-act step. If the pre-checks did not find a `<CODE-UPPER>-CommDev-Attachment-Migration` CloudFormation stack in `legacy-Shared-Services` (343823317319) in **either** us-east-1 or us-west-2, confirm that once more here and skip the rest of this phase.

If a stack does exist:

1. Confirm the bucket (`cst-dc-customer-transfer-commdev-<code>`) is empty or that its contents have been handled per data-retention requirements — CloudFormation stack deletion of a non-empty bucket will fail (by design; do not force-empty it without confirming retention with the requester first).
2. Delete the CloudFormation stack, in the region it was actually found (do not assume us-east-1):
   ```powershell
   aws cloudformation delete-stack --stack-name <CODE-UPPER>-CommDev-Attachment-Migration `
       --profile legacy-Shared-Services --region <region>
   ```
3. Poll until `DELETE_COMPLETE`, or investigate stack events if it fails.
4. Manually revoke/delete the IAM user's access key first if the bucket-empty check in step 1 required manual intervention — deleting the stack removes the IAM user itself but not any access key material that may have been distributed to the client for rclone use; confirm with the requester that the client's ongoing transfer process (if any) has been told this credential is being retired.

### 8. Remove the legacy web/RD server footprint, if any

If the pre-checks found a legacy web server and/or RD server for this client, decommission it using [`legacy-server-decommission.md`](legacy-server-decommission.md)'s main procedure plus its "CommDev (TRAKiT/SSRS) — Legacy Decommission Specifics" section — **skip that runbook's own backup step, since it was already covered here in Phase 0** (start from its LogicMonitor step, or whichever comes next for the servers actually present). Expect the footprint found in the pre-checks, not a fixed count — real examples include a full test-web+RD pair, an RD server with no web server, a web server with no RD server, or no legacy footprint at all.

Do not skip this phase because the tenant is "native" — the two decommissions are independent and both must complete for the client to be fully removed. If the pre-checks found nothing, this phase is a documented no-op.

### 9. Hand off to the DBAs for database work

Once Phases 0–8 are complete, notify the DBAs with the tenant code and every environment in scope so they can remove the tenant's database and its backups. This is the last step in the actual decommission — **do not close out the RFC until the DBAs confirm this is done**; database data/backup removal is entirely their responsibility, not a CloudOps action.

### 10. Delete the local client-specific artifact files

Phases 0 and 1 create instance-manifest and backup-result CSVs (and Phase 6 may leave parameter-dump JSON files) in `scripts/aws/decommission/` — these are working files for *this* decommission, not documentation, and must not be committed. `.gitignore` already excludes the common naming patterns (`*-decommission-*.csv`, `decommission-backups-*.csv`, `*_prod_params.json`, `*_stg_params.json`, `*-instances.csv`) as a backstop, but don't rely on that alone — **delete the files for this tenant from `scripts/aws/decommission/` once Phase 9 is confirmed complete**, so the folder doesn't silently accumulate every prior decommission's client-specific files. Keep only the reusable scripts (`New-DecommissionSnapshot.ps1`, `Stop-DecommissionedInstances.ps1`, `Remove-DecommissionedInstances.ps1`, `batch_delete_params.py`).

---

## Verification

- Backup manifest CSV shows `State=COMPLETED` for every EC2 instance in scope — native and legacy — before the RFC is filed (Phase 0), and the recovery point links appear in the filed RFC (Phase 1).
- LogicMonitor device/website count decreased by the expected number (Phase 2).
- The tenant's `comdev`/`commdev` block no longer appears in `prd.tfvars`/`stg.tfvars` on `master` after the PR merges, the corresponding `legacy_apis` entries (if any) are also gone, `finance`/`utilities` blocks for the same client (if any) are untouched, and CHANGELOG.md reflects the change (Phase 4).
- `terraform apply` output/plan shows the tenant's EC2 instances and volumes destroyed, and a follow-up `aws ec2 describe-instances` filtered on the tenant code returns nothing in the affected region(s) — including any old/replaced instance (Phase 4).
- `docker service ls | grep <tenant-code>` returns nothing in every environment in scope, and `docker stack ls` no longer lists a stack for the tenant (Phase 5).
- Parameter Store search for `/tenant/<tenant-code>` returns nothing, checked with a method immune to the Git Bash path-mangling gotcha (Phase 6).
- CloudFormation stack `<CODE-UPPER>-CommDev-Attachment-Migration`, if it existed, shows `DELETE_COMPLETE` or no longer exists, in the region it was actually found (Phase 7).
- Legacy web/RD footprint, if any, passes the verification section of `legacy-server-decommission.md` (Phase 8).
- DBAs have confirmed database/backup removal (Phase 9) — get this confirmation in writing for the RFC before closing it out.

---

## Rollback

- **Before the Terraform PR is merged/applied:** fully reversible — close the PR, no infrastructure has changed yet.
- **Terraform apply (Phase 4):** EC2 instances and volumes are destroyed on apply — not reversible via this runbook. Recovery is restoring the tenant's block (and any removed `legacy_apis` entry) from git history and re-applying, then restoring data from the DBA-managed backups and the EC2 recovery point taken in Phase 0 (new instance, not in-place — expect a new instance ID and reconfiguration).
- **Docker services (Phase 5):** not reversible via this runbook once removed — the service definition/image reference is gone. Since this phase runs only after the Terraform apply, recovery at this point means the same Terraform-restore path as above, followed by re-deploying the tenant's Docker stack.
- **S3 attachment stack (Phase 7):** not reversible once deleted — bucket and IAM user are gone. If contents were retained per step 1's check, they must be recovered from wherever they were archived, not from the deleted bucket.

---

## Related

- [`legacy-server-decommission.md`](legacy-server-decommission.md) — used by Phase 8 for the legacy web/RD footprint, and as the general pattern this runbook mirrors
- [`commdev-ssrs-client-provisioning.md`](commdev-ssrs-client-provisioning.md) — provisioning runbook for the legacy footprint referenced in Phase 8
- [`commdev-parameter-store-access.md`](commdev-parameter-store-access.md) — console access for Phase 6
- `Troubleshooting Guides/Community Development/docker-service-restart.md` — Docker service naming/order reference and manager/worker instance inventory for both environments (illustrative — actual services present vary per tenant, see Phase 5)
- `.claude/skills/docker-restart/SKILL.md`, `.claude/skills/pasp-ppt-disk-expand/SKILL.md` — related automation for restarting (not removing) tenant services, and for Terraform-based disk changes in the same repo
- `.claude/skills/commdev-attachment-migration/SKILL.md`, `scripts/commdev-attachment/New-CommDevAttachmentBucket.ps1` — provisioning counterpart to Phase 7
- `scripts/aws/decommission/New-DecommissionSnapshot.ps1` — reused as-is in Phase 0; remember its built-in `-BackupVaultName`/`-IamRoleArn` defaults are legacy-account values and must be overridden for PASP accounts
- `scripts/azdo/New-PRViaRest.ps1` — required for Phase 4 (not `New-PR.ps1`; see `/pasp-ppt-disk-expand` for why)
- `aws-configs/accounts.json` — account profile/SSO session resolution for `PROD-PA-Pro` / `Pa-pro-staging`
