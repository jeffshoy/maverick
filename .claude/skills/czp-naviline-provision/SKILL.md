---
name: czp-naviline-provision
description: Provision a new NaviLine CZP (Click2Gov) client server — launches EC2 from the golden AMI/launch template, domain joins to aspgov.pri, activates Windows against AWS KMS, generates an RDP certificate, moves the computer to aspgov.pri/C2G, applies WSUS/TLS group memberships, runs gpupdate + reboot, and optionally creates internal (aspgov.pri, aspgov.com) and public Azure DNS records. Use when onboarding a new NaviLine CZP client (e.g. "/czp-naviline-provision AUGU 172.30.12.14 east"). PREREQUISITE — one-time only: ASPGOV\svc-czp-navi-prov must exist with delegated rights (see New-CzpNavilineServiceAccount.ps1) and its password must be stored as SSM Parameter /czp-naviline/svc-czp-navi-prov in PALegacyCzp and PALegacySharedServices, both us-east-1 and us-west-2.
---

# /czp-naviline-provision — New NaviLine CZP Client Provisioning

## Parsing

- **ClientCode**: short uppercase client code (e.g. AUGU)
- **IPAddress**: internal IP reserved in Netbox for the client's server
- **Region**: `east` or `use1` (us-east-1), `west` or `usw2` (us-west-2) — pick by client timezone (Eastern/Central → east/use1, Mountain/Western → west/usw2)
- **Environment** (optional): `Prod` or `Test`. If not given in the invocation, the script prompts interactively and defaults to Prod.
- **PublicIPAddress** (optional): public IP for the Azure DNS A record. If DNS creation proceeds without it, the script prompts separately — leaving that blank skips only the public Azure record, not the internal aspgov.pri/aspgov.com records.
- **CreateDns** / **SkipDns** (optional switches): skip the "create DNS records?" prompt and force proceed/skip respectively.
- **ExistingInstanceId** (optional): resume a prior run against an already-launched, already-domain-joined instance. Skips EC2 launch and the tiered domain join; starts from confirming domain join, then runs AD config, gpupdate/reboot, and DNS as normal. Use when a prior run failed or exited after the instance was launched/joined but before AD config completed.

**IP sanity check:** Netbox prefixes are 172.30.12.0/24 (use1) and 172.29.12.0/24 (usw2). If the given IP doesn't fall in the expected range for the chosen region, the script warns but does not block — verify the Netbox reservation is correct.

## Accounts

- Client instance: PALegacyCzp (797320052894, foundation) — profile `PALegacyCzp`
- AD work (via DC): PALegacySharedServices (361362055558, foundation) — profile `PALegacySharedServices`

## Launch Templates

| Region | Template ID | Name |
|--------|-------------|------|
| us-east-1 | `lt-0835492de97e6e968` | czp-naviline-use1 |
| us-west-2 | `lt-0f44a807767fb1341` | czp-naviline-usw2 |

## DC for AD work

Must be a DC that both is SSM-online AND hosts the `aspgov.pri` DNS zone directly (confirmed via `Get-DnsServerZone`) — not every SSM-online DC does. Also used for the internal aspgov.pri A-record check in the DNS step.

- us-east-1: `i-0b1671eddda2d5ab2` (inf-svrdc101) — profile PALegacySharedServices, region us-east-1
- us-west-2: `i-06d5b0b213faddcf6` (INF-SVRDC111) — profile PALegacySharedServices, region us-west-2

**Requires `AWS.Tools.SimpleSystemsManagement` installed for all users** (`Install-Module -Scope AllUsers`, since SSM Run Command executes as SYSTEM) — this provides `Get-SSMParameterValue`, used to fetch the service account password. Not installed by default on either DC; confirm before first use.

## Service Account & SSM Parameter

- `ASPGOV\svc-czp-navi-prov` — created via `scripts/czp-naviline/New-CzpNavilineServiceAccount.ps1` (one-time, run manually by an AD admin — NOT part of this skill's flow)
- `/czp-naviline/svc-czp-navi-prov` (SecureString) — must exist in PALegacyCzp AND PALegacySharedServices, both us-east-1 and us-west-2 (4 parameters total)
- If the parameter is missing, the provisioning run fails fast at the domain-join step with a clear error rather than hanging

## DNS Records

Created via SSM Run Command as SYSTEM directly on the target DNS host (no delegated service account needed — same pattern `runbooks/legacy-server-decommission.md` uses for DNS removal). All idempotent — safe to re-run.

| Record | Zone/Server | Target | Notes |
|--------|-------------|--------|-------|
| Host A | `aspgov.pri`, on the region's DC (same DC used for AD config) | `<ComputerName>.aspgov.pri` → private IP | May already exist from dynamic DNS self-registration on domain join — script treats "already exists" as success |
| CNAME | `aspgov.com` internal zone, always on `inf-svrdns001` (`i-04d29591f3a1ba9f4`, profile PALegacySharedServices, us-east-1 — fixed regardless of client region) | `<clientcode>-egov.aspgov.com` and `s-<clientcode>-egov.aspgov.com` → `<ComputerName>.aspgov.pri` | Two CNAMEs, always both created together |
| A (public) | Azure DNS, `aspgov.com` zone, subscription `991cd2ea-42a9-40c0-819d-557f37a3ae2b`, resource group `Azure_DNS_RG` | `<clientcode>-egov.aspgov.com` → public IP | Requires `az login`; if a record already exists with a different IP, the script asks for explicit confirmation before overwriting |

## Action

Run via the Bash tool from the cloudops repo root:

```
pwsh scripts/czp-naviline/Invoke-CzpNavilineProvision.ps1 `
    -ClientCode <CODE> `
    -IPAddress <IP> `
    -Region <east|use1|west|usw2> `
    -Environment <Prod|Test> `
    -PublicIPAddress <PublicIP> `
    -CreateDns
```

Omit `-Environment` to be prompted interactively (defaults to Prod on Enter). Omit `-CreateDns`/`-SkipDns` to be prompted whether to create DNS records after gpupdate/reboot (defaults to Yes on Enter); omit `-PublicIPAddress` to be prompted for it separately at that point.

## Flow

1. Validate IP falls in the expected /24 for the region (warn only)
2. Auto-refresh the `foundation` AWS SSO session if expired for both PALegacyCzp and PALegacySharedServices — no manual login required
3. Launch EC2 in PALegacyCzp from the region's launch template with the given IP and tags
4. Poll SSM every 30s until the instance appears (5–10 min typical)
5. Rename to `<CLIENTCODE>-<P|T>C2GWB001` and domain-join aspgov.pri directly into `aspgov.pri/C2G` via three-tier fallback: Add-Computer via SSM → djoin.exe offline join → manual RDP prompt (last resort only)
6. Confirm domain join
7. Activate Windows against AWS KMS (`slmgr /skms 169.254.169.250; slmgr /ato`) — GPO later overrides the KMS server to an address unreachable from the CZP subnet, so this must happen before gpupdate applies that policy. Non-fatal if it can't be confirmed — warns and continues.
8. Generate an RDP certificate: trigger domain CA auto-enrollment (`certutil -pulse`), poll for up to ~2 minutes, fall back to a self-signed cert bound to the RDP listener if the CA doesn't issue one in time. Non-fatal if it fails — warns and continues (hostname RDP may show NLA errors; IP-based RDP still works).
9. Run `Set-CzpNavilineAdConfig.ps1` on the aspgov.pri DC, authenticating as `svc-czp-navi-prov` via `-Credential` on each AD cmdlet (same direct-credential pattern as the domain-join step — no PSSession/WinRM loopback) — confirms/fixes OU placement and applies `WSUS_PROD_2AM_GROUP` + `Apply_Schannel_TLS1_2_Enabled` membership (idempotent; the join step in #5 already places it in the right OU, this step is the safety net if djoin/Tier-1 OU targeting didn't take). Gated on an explicit success marker in the output, not just SSM's own command status.
10. Run `gpupdate /force` on the client server, then reboot
11. Prompt to create DNS records (unless `-CreateDns`/`-SkipDns` given) — internal aspgov.pri A record, internal aspgov.com CNAMEs on inf-svrdns001, and public Azure A record (only if a public IP was provided)
12. Report summary + activation/RDP-cert status + DNS results + remaining manual steps: SecureLink entry, RFC update in Salesforce, F5 BIG-IP WAF configuration

**Note for the operator:** if you need hostname-based RDP to the new server right away, run `klist purge` on your own workstation first — this clears stale Kerberos tickets for the newly domain-joined computer account. Connecting by IP always works immediately without this. The script prints this reminder in its final summary.

## Tags applied at launch

| Tag Key | Value |
|---------|-------|
| `Name` | `<CLIENTCODE>-<P\|T>C2GWB001` |
| `cst_name` | `<CLIENTCODE>-<P\|T>C2GWB001` |
| `cst_cost_center` | `<CLIENTCODE>` |
| `cst_tenant` | `<clientcode_lowercase>` |

(Everything else — `cst_application`, `cst_tenancy`, `cst_backup_policy`, `DataDog`, `CloudWatchAgent`, `cst_environment`, `cst_compliance_domain`, `cst_product_line` — is baked into the launch template.)

## Examples

- "/czp-naviline-provision AUGU 172.30.12.14 east"
- "/czp-naviline-provision AUGU 172.30.12.14 use1 Test"
- "/czp-naviline-provision AUGU 172.30.12.14 east Prod 203.0.113.10" (with public IP for DNS)
- Resume: `pwsh scripts/czp-naviline/Invoke-CzpNavilineProvision.ps1 -ClientCode AUGU -IPAddress 172.30.12.14 -Region east -ExistingInstanceId i-0c4400e40b1e97ea2 -CreateDns -PublicIPAddress 203.0.113.10`
