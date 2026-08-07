---
name: pasp-ppt-disk-expand
description: Expand EBS disk space for PASP (PA Cloud/ComDev/Finance/Utilities) or PPT (Property Tax) tenants via Terraform, since these environments cannot be resized directly via the AWS API. Use when a disk-capacity alert or ticket names a PASP or PPT tenant server (e.g. "/pasp-ppt-disk-expand pasp belt comdev data_volume_size", "increase disk on the guelph CZP box in PPT", "PASP finance client ANCO needs more D: space").
---

# /pasp-ppt-disk-expand — Expand PASP/PPT tenant disk via Terraform

Unlike other PA environments (see [`runbooks/disk-expansion.md`](../../runbooks/disk-expansion.md)), **PASP and PPT tenant EBS volumes are defined in Terraform, not resized directly via `ec2:ModifyVolume`.** This skill prepares and opens the Terraform PR. It does **not** run `terraform apply` and does **not** extend the OS partition — those are separate, later steps a human completes (see Notes).

## Why this exists

- **PASP** (`$env:USERPROFILE\repos\pasp-tenants`) — no CI/CD pipeline exists for this repo (confirmed in `docs/tenant_infrastructure.md`). After merge, an engineer runs `terraform plan`/`apply` locally against the correct workspace.
- **PPT** (`$env:USERPROFILE\repos\ppt-tenants`) — has a real Azure DevOps pipeline (`azure-pipeline.yml`) with `dev_tf_apply` → `stg_tf_apply` → `prd_tf_apply` stages, each gated by an AzDo environment approval. Merging the PR is enough to kick off `dev`; `stg`/`prd` need their approval gates clicked by whoever owns that environment.

Both repos are **local clones** on this machine and both default to branch **`master`** (not `main` — confirmed via `git branch --show-current`/`git remote show origin`; don't assume otherwise). Verify they exist and are on a clean `master` before starting (`git status`, `git branch --show-current`). If either repo isn't present locally, stop and ask the user for the correct path — don't guess or clone.

## Parsing

Extract from the user's input:

- **`$stack`** — `pasp` or `ppt`. Ask if ambiguous (e.g. a server name alone doesn't disambiguate — `-com` suffix could be either PASP ComDev or unrelated; confirm explicitly).
- **`$env`** — `prd` or `stg` (PASP) / `dev`, `stg`, or `prd` (PPT). Ask if not stated — never assume prod.
- **`$tenant`** — the client/tenant code, lowercase (e.g. `belt`, `guelph`).
- **`$app`** — required for PASP only (e.g. `comdev`, `finance`, `utilities`, `gis`). Not applicable to PPT (PPT vars are flat per-tenant, no per-app nesting).
- **`$variable`** — which size variable to change:
  - PASP: `instance_root_size` (C:\), `data_volume_size` (D:\), `user_volume_size` (E:\)
  - PPT: `czp_volume_size` (root/C:\), `czp_data_volume_size` (data/D:\) — these are used ad hoc per tenant, not yet standardized in the tenant template; grep the tenant's existing yml first to confirm which one(s) it already sets.
- **`$newSizeGB`** — the target size. If the user gives a drive letter instead of a variable name, map it using the tables above and confirm the mapping with the user before proceeding.

If the user gives a drive letter and current usage but not a target size, apply the sizing policy below and show the computed number before proceeding — don't apply it silently.

## Sizing policy (applies to both PASP and PPT)

- **Standard increase:** 30% over current value, rounded to a sensible whole number (e.g. 100 → 130).
- **Hard cap:** 1000 GB without prior account-manager approval.
- **If a 30% increase would exceed 1000 GB:**
  - Option A: cap at 1000 GB (no approval needed) — default unless the user says otherwise.
  - Option B: apply the full 30% (requires the user to confirm account-manager approval was already obtained).
- **If already above 1000 GB:** assume prior approval covers it; apply the 30% increase and note this assumption in the PR description.

Always show the current value → proposed value and which rule applied before writing anything.

## Action

### 1. Locate and confirm the current value

**PASP:**
```powershell
cd "$env:USERPROFILE\repos\pasp-tenants"
git status
git checkout master
git pull
Select-String -Path "environment_tenants\<prd|stg>.tfvars" -Pattern "<tenant>" -Context 0,15
```
Find the `<app>` block under `<tenant>` and confirm the current value of `<variable>`.

**PPT:**
```powershell
cd "$env:USERPROFILE\repos\ppt-tenants"
git status
git checkout master
git pull
Get-Content "vars\<dev|stg|prd>\<tenant>.yml" | Select-String "czp"
```
Confirm whether `czp_volume_size` / `czp_data_volume_size` already exist in this tenant's file. If the variable doesn't exist yet, adding it is a bigger change than a routine bump — flag this to the user and confirm the exact key name/indentation to use before writing (check a sibling tenant file that already has it, e.g. `guelph.yml`, as a template).

### 2. Show the diff plan and get explicit confirmation

Print:
```
Stack:       <pasp|ppt>
Environment: <prd|stg|dev>
Tenant:      <tenant>
App:         <app>          (PASP only)
Variable:    <variable>
Current:     <old>GB
Proposed:    <new>GB   (rule applied: <30% increase | capped at 1000 | already >1000, 30% applied>)

Proceed? (yes/no)
```
Wait for the user to confirm before touching any file.

### 3. Make the change, branch, commit

**PASP:**
```powershell
git checkout -b disk-expand/<tenant>-<app>-<variable>-<date:yyyyMMdd>
# Edit environment_tenants/<env>.tfvars — update the <variable> value for tenants.<tenant>.<app>
```
Also update `CHANGELOG.md` under `## [Unreleased]`:
```markdown
## <MM-DD-YYYY>
### Changed
- `<env>.tfvars` - increased <tenant> <app> <variable> from <old> to <new> (disk capacity <alert|ticket ref>)
```

**PPT:**
```powershell
git checkout -b disk-expand/<tenant>-<variable>-<date:yyyyMMdd>
# Edit vars/<env>/<tenant>.yml — update or add the <variable> line
```
No CHANGELOG.md exists in the tenant.yml-per-file pattern used here — skip that step for PPT (check `git log --oneline -- vars/` first if unsure; don't invent a changelog convention that isn't already there).

Then, in the relevant repo directory:
```powershell
git add <changed files>
git commit -m "Increase <tenant> <app|> <variable> from <old>GB to <new>GB (disk capacity alert)"
git push -u origin <branch-name>
```

### 4. Open the PR via `New-PRViaRest.ps1` (not `New-PR.ps1`)

**Use `scripts\azdo\New-PRViaRest.ps1`, not `scripts\azdo\New-PR.ps1`, for this skill.** `New-PR.ps1` calls `az repos pr create`, which requires the `azure-devops` az CLI extension — on this machine, `az extension add --name azure-devops` crashes with an access violation (0xC0000005) in the CLI's bundled Python/pip (confirmed via `--debug`; a corrupted local install, not a network/auth issue). `New-PRViaRest.ps1` hits the Azure DevOps REST API directly via `az rest` instead (same pattern as `New-CloudWorkRequest.ps1` already uses for work items), so it works regardless of that extension being broken. If a future teammate reports `New-PR.ps1` now works for them (extension fixed), either script is fine — but default to `New-PRViaRest.ps1` unless told otherwise.

The PR description **must include the exact CHANGELOG.md entry text** (PASP only — see step 3) as its own fenced block within the Summary section, not just a reference to "see CHANGELOG.md" — this makes the change reviewable without needing to open a second file.

Write the PR description to `C:\Temp\pr-<tenant>-<variable>-<date>.md`, then from the same repo directory:
```powershell
pwsh "$env:USERPROFILE\repos\cloudops\scripts\azdo\New-PRViaRest.ps1" `
    -Title "Increase <tenant> <app|> <variable> from <old>GB to <new>GB (disk capacity)" `
    -DescriptionFile "C:\Temp\pr-<tenant>-<variable>-<date>.md" `
    -TargetBranch master
```
`New-PRViaRest.ps1` derives org/project/repo automatically from the current directory's git remote — just make sure you're `cd`'d into `pasp-tenants` or `ppt-tenants` first. Its `-TargetBranch` already defaults to `master`, but pass it explicitly anyway for clarity.

PR description must follow the team's standard structure (Summary / Test plan / Blast radius) — see the root `CLAUDE.md` "PR descriptions" section. Blast radius must explicitly state: which tenant/app, which environment, and — for PPT — that merging will auto-trigger the `dev` apply stage (and that `stg`/`prd` require a manual AzDo approval click by the environment owner). Use plain ASCII hyphens (`-`), not en-dashes (`—`), in the description file — en-dashes have shown up mangled (`�`) in the rendered PR body via `az rest`.

Report the PR URL the wrapper prints. Do not fabricate a URL.

## Reporting

After opening the PR, tell the user exactly what remains manual:

- **PASP:** "PR opened. After it's merged, someone needs to run `terraform plan`/`apply` locally against the `<env>` workspace (see `pasp-tenants/README.md` — set `AWS_PROFILE`, `terraform workspace select <env>`, `terraform plan -out plan.tfplan -var-file environment_tenants/<env>.tfvars`, `terraform apply plan.tfplan`) before the EBS volume actually grows."
- **PPT:** "PR opened. Merging to `master` auto-triggers the `dev_tf_apply` stage. `stg_tf_apply` and `prd_tf_apply` each need a manual approval in the AzDo `PPT-STG`/`PPT-PRD` environment gate before they run."
- **Both:** "Once the EBS volume is actually resized (Terraform apply complete), the OS partition still needs to be extended — SSM into the instance and run `Update-Disk` / `Resize-Partition` per [`runbooks/disk-expansion.md`](../../runbooks/disk-expansion.md) Rollback/Verification sections, same as any other EBS expansion." This skill does not do that step — it only handles the Terraform side.

## Examples

- "/pasp-ppt-disk-expand pasp belt comdev data_volume_size 150" → PASP, tenant `belt`, app `comdev`, variable `data_volume_size`, target 150GB — confirm environment (prd/stg) since not given.
- "increase disk on guelph CZP in PPT prod, current is 250GB, D: is almost full" → PPT, `prd`, tenant `guelph`, variable `czp_data_volume_size` — since no target given, apply the 30% rule (250 → 325) and confirm before proceeding.
- "PASP finance client ANCO needs more D: space in staging" → PASP, `stg`, tenant `anco`, app `finance`, variable `data_volume_size` (D: maps to `data_volume_size` per the drive table) — ask for current value or look it up, then apply sizing policy.

## Notes

- **Never** run `terraform apply` (or trigger a pipeline approval) as part of this skill — that's a separate, explicitly-requested action per the team's Plan-mode-for-prod and human-in-the-loop standards. This skill's job ends at "PR opened."
- **Never** guess the tenant/app/variable name — if the tfvars or yml file doesn't have an obvious matching block, stop and ask rather than inventing a new key.
- If either local repo (`pasp-tenants` or `ppt-tenants`) has uncommitted changes or isn't on `master` when you start, stop and ask the user how to proceed — don't stash/discard their in-progress work.
- EBS volumes cannot be shrunk — the same irreversibility warning from `runbooks/disk-expansion.md` applies once the Terraform apply actually runs.
- If the PPT tenant's yml file doesn't yet have a `czp_volume_size`/`czp_data_volume_size` key at all, this is effectively adding new infrastructure config, not a routine bump — treat it with the same care as a first-time tenant setup and double-check against a sibling tenant file before writing.
