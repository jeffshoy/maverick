# Legacy Server Decommission (Snapshot → Stop → Terminate)

## When to use

- A ticket/RFC requests permanently decommissioning one or more **legacy** EC2 instances (client offboarding, migration complete, consolidation) — servers migrated in via AWS Application Migration Service (MGN) / lift-and-shift into a legacy org account, identifiable by tags like `AWSApplicationMigrationServiceManaged`, `cst_backup_policy`, `cst_tenant`, etc.
- **This procedure is specific to legacy accounts and does not apply to native/cloud-native AWS workloads** — those are provisioned and decommissioned differently (e.g. via Terraform/CloudFormation teardown, not manual AWS Backup + DNS/NetBox cleanup) and are out of scope here.
- Applies to accounts using tag-driven AWS Backup plans (check for a `cst_backup_policy` tag on the instance and matching backup plans/selections in the account before assuming this pattern fits).

---

## Pre-checks

- [ ] **RFC/change ticket approved** — do not stop-then-terminate, or terminate, before approval is confirmed. Stopping instances ahead of approval (to reduce cost/exposure while waiting) is acceptable only if the ticket/requester explicitly asked for that sequencing.
- [ ] Confirm the account has existing AWS Backup plans/vaults before assuming they exist — check `aws backup list-backup-plans` and `aws backup list-backup-selections --backup-plan-id <id>` for a tag condition (e.g. `cst_backup_policy=prod`) that already covers the target instances. If none exist, this runbook's snapshot step needs to fall back to raw `aws ec2 create-image` instead (not covered by the scripts here — treat as a variant).
- [ ] Verify the exact instance list against live EC2 state (`aws ec2 describe-instances --profile <profile>` across all relevant regions) — do not trust a pasted list at face value. Watch for encoding artifacts (e.g. Cyrillic look-alike characters copy-pasted from a ticket system) that silently don't match any real instance.
- [ ] Confirm with the requester that every target server is actually decommissioned/out of service from an application standpoint — termination is unrecoverable within minutes; a backup restore is not an instant failback.
- [ ] AWS SSO session active for the target account.
- [ ] Confirm the internal domain (e.g. `aspgov.pri`), Azure DNS zone (e.g. `aspgov.com`), and NetBox instance (`https://netbox.aspgov.com/`) that these servers are actually registered under — do not assume it matches other documented environments without checking (product line / account naming can differ).
- [ ] Record each target instance's internal (private) IP and external/public-facing IP (if any) in the RFC/ticket *before* touching anything. External IPs for legacy web servers are often not attached to the EC2 instance directly (no `PublicIpAddress`/Elastic IP) — they're a separate DNS A record (e.g. Azure `aspgov.com` zone) pointing at a NAT/F5 translation. Find the candidate record by searching the DNS zone for the client code (`az network dns record-set list --zone-name aspgov.com --resource-group Azure_DNS_RG --query "[?contains(name, '<clientcode>')]"`), then confirm with the requester which record maps to which instance before relying on it in Step 8 — don't infer purely from naming.

---

## Procedure

### 1. Build the instance manifest

Create a CSV with columns `Name,InstanceId,Region` from the verified live-state lookup (see Pre-checks). Save it alongside the decommission scripts, e.g. `scripts/aws/decommission/<ticket>-instances.csv`.

### 2. Take a final, explicitly-retained backup

```powershell
pwsh scripts/aws/decommission/New-DecommissionSnapshot.ps1 `
    -Profile <AccountProfile> `
    -InstanceListCsv .\<ticket>-instances.csv `
    -TicketRef <RFC-or-ticket-ref> `
    -RetentionDays 180 `
    -WhatIf
```

Review the `-WhatIf` output, then re-run without `-WhatIf`. This triggers one on-demand AWS Backup job per instance into the account's existing `BackupVault`, tagged with the ticket reference and an explicit `DeleteAfter` date — independent of whatever the instance's regular scheduled backup cadence happens to provide. Do not proceed until every instance shows `State=COMPLETED` in the output CSV (`decommission-backups-<ticket>-<date>.csv`). Any instance that fails or times out must be investigated and re-run individually before continuing — never proceed to stop/terminate with a partial manifest.

### 3. Remove from LogicMonitor

Manual step — no API integration exists in this repo for LM device management:

1. Log into the LogicMonitor portal.
2. Search for each server name from the manifest.
3. Delete or disable the device (confirm with your LM admin which action is standard for decommissions — delete removes history, disable retains it but stops active checks).
4. Record the before/after device count for the RFC evidence.

### 4. Stop the instances

```powershell
pwsh scripts/aws/decommission/Stop-DecommissionedInstances.ps1 `
    -Profile <AccountProfile> `
    -BackupManifestCsv .\decommission-backups-<ticket>-<date>.csv `
    -WhatIf
```

Review, then re-run without `-WhatIf`. The script refuses any instance whose backup job didn't reach `COMPLETED`. Confirms each stop interactively unless `-Force` is passed.

> **Non-interactive sessions (e.g. Claude Code / CI):** the interactive `ShouldProcess` confirm prompt throws `Exception calling "ShouldProcess" with "2" argument(s): "Object reference not set to an instance of an object."` when there's no real console host to render the prompt. In that case, re-run with `-Force` after the human operator has explicitly confirmed the action in chat/ticket — `-Force` does not skip the `COMPLETED`-backup safety check, only the per-instance confirm.

### 5. Wait for RFC approval

Do not proceed to termination until the change ticket is explicitly approved. Stopped instances remain fully recoverable via `aws ec2 start-instances` during this window.

### 6. Terminate (irreversible)

```powershell
pwsh scripts/aws/decommission/Remove-DecommissionedInstances.ps1 `
    -Profile <AccountProfile> `
    -BackupManifestCsv .\decommission-backups-<ticket>-<date>.csv `
    -RfcApproved `
    -WhatIf
```

Review, then re-run without `-WhatIf`. Requires `-RfcApproved` explicitly — the script refuses to run without it. Re-verifies each instance is both backed up (`COMPLETED`) and currently `stopped` immediately before terminating (does not trust the manifest alone). Confirms each termination interactively unless `-Force` is passed.

> Same non-interactive caveat as Step 4 applies here — use `-Force` only after explicit human confirmation of the live (non-`-WhatIf`) run, since this step is irreversible.

After termination, confirm the final state directly rather than trusting the script's own summary alone:

```powershell
aws ec2 describe-instances --profile <AccountProfile> --region <Region> `
    --instance-ids <id1> <id2> <id3> `
    --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,InstanceId:InstanceId,State:State.Name}" `
    --output table
```
All targeted instances should show `State=terminated`.

### 7. Remove internal DNS records (aspgov.pri)

**Preferred path — from a workstation with direct network/VPN reachability to a domain controller** (e.g. connected via Cisco AnyConnect):

```powershell
pwsh scripts/dns/Remove-DnsRecord.ps1 `
    -Zone aspgov.pri `
    -Server <DCName> `
    -HostName <ServerName> `
    -WhatIf
```

Review, then re-run without `-WhatIf`. This is a separate script from `change-dns-ms.ps1` (which only handles old-IP→new-IP migration, not deletion). Requires RSAT `DnsServer` module and a workstation that can actually resolve/reach the DC by name — check with `Resolve-DnsName <DCName>` first. Logs to `remove-dnsrecord_<hostname>_<timestamp>.log` — attach to the change ticket.

**Fallback path — no direct network/VPN reachability to the DC** (e.g. running from a machine/session without the corp VPN connected, such as an unattended Claude Code session): AWS SSM Run Command can reach the DC directly since it's an EC2 instance with the SSM agent online, without needing this workstation to be on the corp network at all. Run the DNS cmdlets *on the DC itself* via `AWS-RunPowerShellScript`, targeting `localhost` as the DNS server:

```powershell
# 1. Confirm the record(s) exist before touching anything
aws ssm send-command --profile <AccountProfile> --region <Region> `
    --instance-ids <DC-InstanceId> `
    --document-name "AWS-RunPowerShellScript" `
    --parameters 'commands=["$Zone = ''aspgov.pri''", "$hosts = @(''<Server1>'',''<Server2>'')", "foreach ($h in $hosts) { $rec = Get-DnsServerResourceRecord -ZoneName $Zone -ComputerName ''localhost'' -Name $h -ErrorAction SilentlyContinue; if ($rec) { foreach ($r in $rec) { Write-Output \"$h : FOUND : $($r.RecordType) : $($r.RecordData.IPv4Address)\" } } else { Write-Output \"$h : NOT FOUND\" } }"]'

# 2. Retrieve output (Command ID from step 1)
aws ssm get-command-invocation --profile <AccountProfile> --region <Region> `
    --command-id <CommandId> --instance-id <DC-InstanceId> `
    --query "{Status:Status, StdOut:StandardOutputContent}" --output json

# 3. After confirming and getting explicit go-ahead, remove — same pattern, swap Get- for Remove-DnsServerResourceRecord -Force
# 4. Re-run the lookup from step 1 to confirm NOT FOUND for every hostname
```

Which DC to target: pick one **in the same region as the decommissioned servers**. DC naming: `inf-svrdc0xx`/`inf-svrdns001` are us-east-1; for the `1xx` series, **`inf-svrdc101`/`102` are us-east-1 and `inf-svrdc111`/`112` are us-west-2** (confirmed by direct lookup — do not assume "1xx = west" from the number alone, the `01` vs `11` second digit is what actually distinguishes region here, not the leading `1`). Always confirm the actual region with `aws ec2 describe-instances --filters "Name=tag:Name,Values=<dc-name>"` across both regions before assuming — do not trust naming pattern alone; check `PALegacySharedServices` account for the actual instance IDs, they are not static across environments. Confirm the DC instance is SSM-online first: `aws ssm describe-instance-information --profile PALegacySharedServices --region <Region> --filters "Key=InstanceIds,Values=<DC-InstanceId>" --query "InstanceInformationList[].PingStatus"`.

**Internal `aspgov.com` CNAME lives on `inf-svrdns001`, in the internal `aspgov.com` DNS zone hosted there — not on the DC handling `aspgov.pri`, and not the external Azure DNS zone.** These are three separate DNS surfaces for the same hostname: (1) `aspgov.pri` A record on a DC like `inf-svrdc101`, (2) internal `aspgov.com` CNAME on `inf-svrdns001` (e.g. `<CLIENTCODE>-TRK-SSRS-RD` → `<clientcode>-ptrkrd001.aspgov.pri.`), (3) external Azure DNS `aspgov.com` zone (Step 8, `az network dns`) — which may not have a record at all if the client's RD server was never given a public-facing entry. Check all three independently; do not assume finding one means the others exist or don't.

This fallback is read-then-write, not `-WhatIf`-gated like the script — always run the read-only lookup (step 1) first, share the found records with the requester/ticket for confirmation, then only run the removal after explicit go-ahead in the same turn.

### 8. Remove Azure DNS records (aspgov.com zone)

Automatable via `az` CLI if the operator has Azure AD auth to the `Azure_DNS` subscription (`991cd2ea-42a9-40c0-819d-557f37a3ae2b`, resource group `Azure_DNS_RG`, zone `aspgov.com`) — this does not require corp VPN/network reachability, just `az login`/SSO.

```powershell
# Confirm current value before deleting (compare against the RFC's recorded external IP)
az network dns record-set a show --zone-name aspgov.com --resource-group Azure_DNS_RG --name <record-name>

# Delete (record-name is the label only, e.g. "gaks-cog" for gaks-cog.aspgov.com)
az network dns record-set a delete --zone-name aspgov.com --resource-group Azure_DNS_RG --name <record-name> --yes

# Verify — expect a NotFound error
az network dns record-set a show --zone-name aspgov.com --resource-group Azure_DNS_RG --name <record-name>
```

Record naming for legacy Cognos web servers observed so far: `<clientcode>-cog` (Cognos 10) vs `<clientcode>-cog11` (Cognos 11) — **do not assume both exist for every client**; some tenants only ever had one record (confirm which record maps to which instance/version with the requester before deleting — don't guess from naming alone).

**`-cog11` is Cognos 11 and is a live, separate service — NEVER delete it as part of a legacy Cognos 10 decommission**, even when it shares the same client code as the instance(s) being terminated. This runbook's Cognos decommissions target the `PCOGWB` (Cognos 10 web server) EC2 instances specifically; the `-cog11` DNS record almost always points at a *different*, still-in-service instance/stack and deleting it takes down a live client. Only delete `<clientcode>-cog` (no `11` suffix). If a client has no `-cog` record at all (only `-cog11`, or neither), there is nothing to remove in this step — do not substitute the `-cog11` record. Record before/after for the change ticket.

Manual fallback (no Azure CLI/API access available): log into the Azure portal → DNS zone `aspgov.com`, find and delete the A record (and any CNAME records pointing at it) for each decommissioned server, record before/after for the change ticket.

### 9. Release IPs in NetBox — manual

No API automation exists in this repo for NetBox. Manually:

1. Log into [NetBox](https://netbox.aspgov.com/) → IPAM → IP Addresses (or Prefixes).
2. Find the IP address reservation for each decommissioned server (see the manifest CSV for private IPs).
3. Delete the IP reservation or mark it as deprecated/available per your NetBox conventions — **do not leave it allocated**, since `commdev-ssrs-client-provisioning.md` explicitly instructs future provisioning to avoid reusing IPs "without confirming they are released."
4. If the server also has a NetBox device/DCIM record (not just an IP), decommission or delete that record too.

---

## Verification

- Backup manifest CSV shows `State=COMPLETED` and a `RecoveryPointArn` for every instance before any stop/terminate step.
- LogicMonitor device count decreased by the expected number.
- Post-stop: `aws ec2 describe-instances` shows all target instances `stopped`.
- Post-terminate: `aws ec2 describe-instances` shows all target instances `terminated` (or they no longer appear in a `running`/`stopped` filtered query).
- `Resolve-DnsName <hostname> -Server <DCName>` fails (NXDOMAIN) for internal DNS after step 7 — or, if using the SSM fallback, a re-run of the `Get-DnsServerResourceRecord` lookup returns `NOT FOUND` for every hostname.
- Azure DNS zone no longer lists the A record after step 8 — `az network dns record-set a show` returns a `NotFound` error for each deleted record name.
- NetBox no longer shows the IP as allocated (or shows it as available/deprecated) after step 9.

---

## Rollback

- **While stopped, before termination:** `aws ec2 start-instances --instance-ids <id> --profile <profile> --region <region>` — fully reversible.
- **After termination:** restore from the tagged recovery point (`RecoveryPointArn` column in the manifest) via AWS Backup's restore workflow. This launches a **new** instance — not an in-place recovery. Expect a new instance ID and follow-up application-level reconfiguration (DNS, IIS bindings, AD rejoin if domain-joined).

---

## Cleanup — delete local artifact files when done

Step 1's instance manifest and Step 2's backup-result CSV (`decommission-backups-<ticket>-<date>.csv`) are working files for *this* decommission, not documentation — do not commit them. `.gitignore` excludes the common naming patterns (`*-decommission-*.csv`, `decommission-backups-*.csv`, `*-instances.csv`) as a backstop, but don't rely on that alone — **delete these files from `scripts/aws/decommission/` once every verification step above is confirmed**, so the folder doesn't silently accumulate every prior decommission's client-specific files. Keep only the reusable scripts (`New-DecommissionSnapshot.ps1`, `Stop-DecommissionedInstances.ps1`, `Remove-DecommissionedInstances.ps1`, `batch_delete_params.py`).

---

## CommDev (TRAKiT/SSRS) — Legacy Decommission Specifics

Applies when the RFC targets a **legacy** CommDev/TRAKiT SSRS client — one provisioned per [`commdev-ssrs-client-provisioning.md`](commdev-ssrs-client-provisioning.md), not a native PASP CommDev tenant. For native CommDev tenants, use [`commdev-native-decommission.md`](commdev-native-decommission.md) instead (that runbook also decommissions a legacy test web/RD pair when one exists, reusing this section).

Follow the numbered procedure above for every server in scope — this section only calls out what's CommDev-specific or additional.

### 0a. Build the manifest and take backups first

Before creating the RFC, identify every server in scope (see "Servers in scope" below) and run Steps 1–2 of the main procedure above (build the instance manifest, take the explicitly-retained backup) for all of them. **The RFC needs each server's recovery point link, so backups must complete before the RFC is filed** — don't create the RFC first and backfill the links later.

### 0b. Gather information and create the RFC

Once backups from 0a show `State=COMPLETED` for every server, assemble the following and attach it to the Salesforce RFC (reference `RFC-37311` as a template, same as the provisioning runbook):

- AWS account(s) in scope and region
- Instance name and ID for every server (see "Servers in scope" below — do not assume only the standard 3)
- Private (internal) IP address for every server
- Public/external IP address — normally only the RD server has one (via the Azure DNS A record, not an attached Elastic IP — see the generic Pre-checks above for how to find it)
- Backup recovery point link/ARN and retention date for every server, from 0a
- Internal DNS (`aspgov.pri`) entries for every server, plus the RD server's internal CNAME
- Azure DNS (`aspgov.com`) entry for the RD server

Only create/submit the RFC once this is fully gathered — do not file it with placeholders to be filled in later. Once the RFC is approved, resume the main procedure from Step 3 (LogicMonitor) — Steps 1–2 are already done from 0a.

### Servers in scope

A standard legacy CommDev client has **three** servers:

| Server | Account | Typical naming |
|--------|---------|-----------------|
| Prod web server | PALegacyCommDev (852998999214) | `<CLIENTCODE>-PTRKWB00x` |
| Test web server | PALegacyCommDev (852998999214) | `<CLIENTCODE>-TTRKWB001` |
| RD server | PALegacySharedServices (361362055558) | `<CLIENTCODE>-PTRKRD001` |

**Before building the instance manifest:** search **PALegacyCommDev** in both regions for every instance tagged `cst_cost_center=<CLIENTCODE>` or matching `<CLIENTCODE>-*TRKWB*`. A small number of clients have more than one prod web server — the manifest must reflect what's actually running, not the typical 3-server pattern.

**Native CommDev client, decommissioning only its legacy test pair:** a native (PASP/Docker Swarm) CommDev tenant has no legacy prod web server — production runs on PASP, not on this account. It typically still has the **test web server + RD server** pair provisioned per `commdev-ssrs-client-provisioning.md` for pre-prod testing. When [`commdev-native-decommission.md`](commdev-native-decommission.md) sends you here for that pair, expect only 2 servers (test web + RD), not 3 — do not go looking for a prod web server that was never provisioned in PALegacyCommDev for this client.

### Steps 7–8 (DNS) — CommDev naming

- Internal DNS (`aspgov.pri`): remove the A record for **every** server in the manifest (`<CLIENTCODE>-PTRKWB00x`, `<CLIENTCODE>-TTRKWB001`, any additional prod web servers, `<CLIENTCODE>-PTRKRD001`).
- Also remove the internal CNAME `<CLIENTCODE>-PTRKRD001.aspgov.pri` → `<CLIENTCODE>-TRK-SSRS-RD.aspgov.com` on `inf-svrdns001.cloud.lcl`.
- Azure DNS (`aspgov.com`): delete `<CLIENTCODE>-TRK-SSRS-RD` only. Web servers normally have no Azure DNS record — don't search for one to "complete" the step.

### Step 9 (NetBox) — CommDev subnets

Confirm released IPs fall within the CommDev reservation ranges before marking them available, so a future provisioning run doesn't collide:

| Resource | East prefix | West prefix |
|----------|-------------|--------------|
| Web server (internal) | 172.30.17.0/24 | 172.29.17.0/24 |
| RD server (internal) | 172.30.41.0/24 | 172.29.41.0/24 |
| RD server (external) | 192.88.54.0/24 / 74.114.65.0/24 | 74.114.66.0/24, 74.114.67.0/24, 74.114.69.0/24 |

---

## Related

- `scripts/aws/decommission/New-DecommissionSnapshot.ps1`, `Stop-DecommissionedInstances.ps1`, `Remove-DecommissionedInstances.ps1`
- `scripts/dns/Remove-DnsRecord.ps1` — internal DNS (aspgov.pri) record removal
- [`dns-record-change.md`](dns-record-change.md) — internal DNS migration (old IP→new IP); this runbook's Step 7 uses a separate deletion-only script instead
- [`aws-sso-setup.md`](aws-sso-setup.md) — if the SSO session is expired
- `aws-configs/accounts.json` — account profile/SSO session resolution
- `runbooks/commdev-ssrs-client-provisioning.md` — reference for NetBox/Azure DNS access URLs and the "don't reuse IPs from decommissioned hosts" convention this runbook's Step 9 exists to satisfy
- [`commdev-native-decommission.md`](commdev-native-decommission.md) — native (PASP/Docker Swarm) CommDev tenant decommission; hands off to this runbook's CommDev section for a client's legacy test web/RD pair
- `scripts/dns/change-dns-ms.ps1` (`$dnsservervmname` list) — the canonical list of DC hostnames when Step 7's `-Server <DCName>` or the SSM fallback needs an actual instance to target: `inf-svrdns001`, `inf-svrdc001/002/011/012/101/102` for us-east-1, `inf-svrdc111/112` for us-west-2 — the script itself doesn't assert region, so this mapping was confirmed by direct `describe-instances` lookup, not assumed from the name. Confirm the current instance ID for the chosen DC in `PALegacySharedServices` — they are not guaranteed stable across rebuilds.
- Azure subscription `Azure_DNS` (`991cd2ea-42a9-40c0-819d-557f37a3ae2b`), resource group `Azure_DNS_RG` — Step 8's `az network dns` commands require `az login`/SSO to this subscription, not the AWS profiles used elsewhere in this runbook.
