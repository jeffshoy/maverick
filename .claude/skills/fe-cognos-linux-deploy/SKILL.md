---
name: fe-cognos-linux-deploy
description: Deploy a new FE 1.0 legacy Cognos Linux client instance from the golden AMI — launches EC2 (network/IAM config auto-discovered from an existing report/job server in the same account), sets hostname, generates/stores an admin password in SSM Parameter Store, and creates internal DNS A records on the client's domain controller. Use when onboarding a new FE 1.0 legacy Cognos Linux client (e.g. "/fe-cognos-linux-deploy ANCO east Test"). Does NOT domain-join, move the AD computer object, or configure Cognos — those remain manual hand-offs.
---

# /fe-cognos-linux-deploy — FE 1.0 Legacy Cognos Linux Client Deployment

## Parsing

- **ClientCode**: short client code (e.g. ANCO). Derives the AWS profile
  `PALegacyFinEnt{CLIENT}` and the AD domain `{client}.cloud.lcl` (lowercased).
- **Region**: `east` or `use1` (us-east-1), `west` or `usw2` (us-west-2).
- **Environment**: `Prod` or `Test`. Determines the `{T|P}ONSLRP001` naming letter and the
  SSM Parameter Store tier (`tst-fe` / `prd-fe`).

Any of ClientCode/Region/Environment not supplied are prompted for interactively.

## Prerequisite: Domain Admin Account in the Client's AD Bubble

Domain join is a manual step performed after this skill finishes (see "What this skill does
NOT do" below). Before running this skill, confirm a domain admin account already exists in
the **client's own AD bubble domain** (`{client}.cloud.lcl`) — this is a separate account per
client, not a shared/central credential. If no domain admin account exists yet for this
client, get one provisioned before deploying, since the domain join immediately follows.

## What this skill does NOT do

- **Domain join** (`realm discover` / `realm join`) — intentionally manual. Interactive
  credential prompts don't work reliably across every surface this skill may run from (e.g.
  non-interactive automation), so this step always requires someone to run it by hand. See
  `runbooks/fe-legacy-cognos-client-deploy.md` Step 6 for the exact commands — the skill's
  final summary also prints them, pre-filled with the instance ID and domain.
- Move the computer object from the default `Computers` container to the client's AD OU
  (e.g. `{client}.cloud.lcl/Computers/{name}` → `{client}.cloud.lcl/{CLIENT}/Servers/{Prod|Test}`)
  — manual step, see `runbooks/fe-legacy-cognos-client-deploy.md` Step 7.
- Configure Cognos itself (content store, gateway URI, auth namespace) — hand off to the
  GlobalLogic team per `runbooks/fe-legacy-cognos-client-deploy.md` Step 9.
- Configure the proxy — already baked into the golden AMI.
- Install security tooling — Tanium is already baked into the golden AMI (v1.3); see
  `runbooks/fe-legacy-cognos-ami-build.md` Phase 8b. No per-client action needed.
- Register the instance with a load balancer.

## Accounts

- Client instance: `PALegacyFinEnt{CLIENT}` — SSO session `foundation` (auto-refreshed if
  expired, no manual login required).

## Golden AMIs (v1.3)

| Region | AMI ID |
|--------|--------|
| us-west-2 | `ami-0f6a4e7c36328cfd0` |
| us-east-1 | `ami-007e574ddf94a654b` |

## Network/IAM Discovery

The script does not take Subnet/Security Group/IAM role as inputs. It discovers them from
an existing reference instance in the same `PALegacyFinEnt{CLIENT}` account/region:

1. First searches for a report server matching `{CLIENT}-*ONSRP*` (any environment).
2. If none found, falls back to a job server matching `{CLIENT}-*ONSJB*` (e.g.
   `ANCO-TONSJB001`).
3. If multiple instances match, the operator is prompted to pick one from a numbered list.
4. If neither pattern matches anything, the run fails with a clear error — it does not guess
   network configuration.

## Tagging

There is no AWS launch template resource for this — each `PALegacyFinEnt{CLIENT}` account
is separate, and launch templates aren't cross-account shareable the way the golden AMI is
(via AMI launch permissions). Instead, the script keeps a generic-tags constant (the
equivalent of "the template") and merges it with per-environment and per-client tags at
`run-instances` time, same net effect without per-account template upkeep.

| Tag Key | Source | Value |
|---------|--------|-------|
| `cst_compliance_domain` | Generic (all clients) | `pci` |
| `cst_product_line` | Generic | `pa_financeenterprise` |
| `cst_tenancy` | Generic | `single` |
| `DataDog` | Generic | `enabled` |
| `CloudWatchAgent` | Generic | `enabled` |
| `cst_application` | Generic | `report_server` |
| `cst_environment` | Per-environment | `tst` (Test) / `prd` (Prod) |
| `cst_backup_policy` | Per-environment | `nonprod` (Test) / `prod` (Prod) |
| `Name`, `cst_name` | Per-client | `{CLIENT}-{T\|P}ONSLRP001` |
| `cst_cost_center` | Per-client | `{CLIENT}` |
| `cst_tenant` | Per-client | `{client}` (lowercase) |

## Password Handling

A single 20+ character random password (via .NET `RandomNumberGenerator`, no plaintext
logging) is generated and applied to **both** `ubuntu` and `ubuntu-admin` on the instance,
then stored as a SecureString SSM Parameter at:

- Test: `/tenant/{client}-tst-fe/cognoslx/admin_password`
- Prod: `/tenant/{client}-prd-fe/cognoslx/admin_password`

## DNS Records

After the instance is launched and its private IP is known, the skill creates two internal
A records via SSM directly on the client's own domain controller — running as SYSTEM, so no
domain admin credential is needed (the DC's machine account already has authority to update
zones it hosts). Both creations are idempotent (skipped with `A_RECORD_EXISTS` if already
present, never overwritten).

**Finding the DC:** searches for a running instance matching `{CLIENT}-*PDC00*` (covers
`PDC001`, `PDC002`, etc. — some clients have more than one DC; any one works since they
share the same zones).

| Zone | Record Name | Target |
|------|-------------|--------|
| `{client}.cloud.lcl` | `{CLIENT}-{T\|P}ONSLRP001` | Instance private IP |
| `{client}cloud.aspgov.com` | `{client}-rptlnx` (Prod) / `{client}-rptlnx-tst` (Test) | Instance private IP |

The `{client}-rptlnx` / `-tst` naming was confirmed for ANCO (2026-08-06) as the standard
going forward, distinct from the existing Windows report-server naming (`anco-rpt` /
`anco-rpt-tst`).

**If the DC can't be found, or the private IP can't be determined, or either SSM command
fails:** the skill WARNS and continues — it does not abort the run, since the instance,
hostname, and password steps have already succeeded. The final summary reports what
happened and, if needed, that DNS records must be created manually per
`runbooks/fe-legacy-cognos-client-deploy.md`.

## Action

Run via the Bash tool from the cloudops repo root:

```
pwsh scripts/fe-cognos-linux/Invoke-FeCognosLinuxDeploy.ps1 `
    -ClientCode <CODE> `
    -Region <east|use1|west|usw2> `
    -Environment <Prod|Test>
```

Omit any parameter to be prompted interactively. Add `-WhatIf` to preview the launch and
discovery steps without creating any resources or setting any passwords.

## Flow

1. Auto-refresh the `foundation` AWS SSO session for `PALegacyFinEnt{CLIENT}` if expired.
2. Discover VPC/Subnet/Security Group/IAM Instance Profile from an existing report or job
   server in the account (see Network/IAM Discovery above).
3. Launch EC2 (`r6a.xlarge`, 100GB encrypted gp3 root) from the golden AMI, tagged/named
   `{CLIENT}-{T|P}ONSLRP001`.
4. Poll SSM every 30s until the instance is Online (up to 15 min); re-fetch the private IP
   once online.
5. Set hostname to `{CLIENT}-{T|P}ONSLRP001`.
6. Generate a password, set it on `ubuntu` and `ubuntu-admin`, store it in SSM Parameter
   Store.
7. Find the client's domain controller (`{CLIENT}-*PDC00*`) and create the two internal DNS
   A records (see DNS Records above) — warns and continues on failure rather than aborting.
8. Report a summary: instance ID, private IP, reference server used, password parameter
   path, DNS record results, log file path, and the exact manual commands for domain join,
   AD OU move, and the Cognos hand-off.

## Troubleshooting: AMI Not Shared With the Client Account

The golden AMI and its KMS key are shared from `PALegacySharedServices` (361362055558) to
specific `PALegacyFinEnt{CLIENT}` account IDs. If `run-instances` fails with an AMI/snapshot
permission error, the new client's account ID hasn't been added to the share list yet.

**1. Share the AMI + snapshot (both regions):**

```powershell
# West
aws ec2 modify-image-attribute --profile PALegacySharedServices --region us-west-2 --image-id ami-0f6a4e7c36328cfd0 --launch-permission "Add=[{UserId=NEW_ACCOUNT_ID}]"
aws ec2 modify-snapshot-attribute --profile PALegacySharedServices --region us-west-2 --snapshot-id snap-0296b4e9096306fe2 --attribute createVolumePermission --operation-type add --user-ids NEW_ACCOUNT_ID

# East
aws ec2 modify-image-attribute --profile PALegacySharedServices --region us-east-1 --image-id ami-007e574ddf94a654b --launch-permission "Add=[{UserId=NEW_ACCOUNT_ID}]"
aws ec2 modify-snapshot-attribute --profile PALegacySharedServices --region us-east-1 --snapshot-id snap-0a46be4f4a2a872d1 --attribute createVolumePermission --operation-type add --user-ids NEW_ACCOUNT_ID
```

**2. Add the new account to the KMS key policy** (the AMI's root volume is encrypted with a
shared KMS key — sharing the AMI alone isn't enough). Add
`"arn:aws:iam::NEW_ACCOUNT_ID:root"` to both `scripts/kms-policy-west.json` and
`scripts/kms-policy-east.json`, then apply:

```powershell
aws kms put-key-policy --profile PALegacySharedServices --region us-west-2 --key-id f17195a0-525f-49be-b625-9fa79e4b0d01 --policy-name default --policy file://scripts/kms-policy-west.json
aws kms put-key-policy --profile PALegacySharedServices --region us-east-1 --key-id 1167100c-cd4f-4e70-acda-9917a7756cb3 --policy-name default --policy file://scripts/kms-policy-east.json
```

Re-run the skill once both steps complete — no other changes needed.

## Examples

- "/fe-cognos-linux-deploy ANCO east Test"
- "/fe-cognos-linux-deploy ANCO use1 Prod"
- Dry run: `pwsh scripts/fe-cognos-linux/Invoke-FeCognosLinuxDeploy.ps1 -ClientCode ANCO -Region east -Environment Test -WhatIf`
