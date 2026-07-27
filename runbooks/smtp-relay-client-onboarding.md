# SMTP Relay — New Client Domain Onboarding

## Overview

This runbook covers adding a new client email domain to the SMTP relay infrastructure. The infrastructure consists of two Windows servers running WSL (Ubuntu 22.04) with Postfix inside, relaying outbound email through AWS SES. When a new client is onboarded, their domain must be registered in SES as a verified identity and added to the Postfix `relay_domains` file on both relay servers.

The entire process is automated via the `/smtp-add-client` Claude skill, which wraps `scripts/smtp/Add-SmtpClient.ps1`.

---

## Infrastructure

| Component | Detail |
|-----------|--------|
| AWS Account | PALegacySharedServices (361362055558, foundation SSO) |
| Relay East | inf-relay001.cloud.lcl — i-034b91ef8516afd72 — us-east-1 |
| Relay West | inf-relay101.cloud.lcl — i-0be7224e91e5b785a — us-west-2 |
| WSL Distro | Ubuntu 22.04 on both relays |
| Postfix config | `/etc/postfix/relay_domains` |
| SES | Configured in both us-east-1 and us-west-2 |
| WSL Windows user | `cloud\svc-wsl-relay` (local Administrators) |
| WSL sudo user | `relayadmin` (different password per region) |

### SSM Parameter Store

Both parameters must exist in **us-east-1 AND us-west-2** under account PALegacySharedServices:

| Parameter | Type | Description |
|-----------|------|-------------|
| `/relay/svc-wsl-relay` | SecureString | Windows password for `cloud\svc-wsl-relay` — same value in both regions |
| `/relay/relayadmin` | SecureString | sudo password for `relayadmin` inside WSL — **DIFFERENT per region** |

> **NOTE:** The `relayadmin` password differs between us-east-1 and us-west-2. The script automatically retrieves the correct one for each relay based on its region.

### relay_domains File Structure

The Postfix `relay_domains` file is structured in labelled sections. New client domains are always inserted alphabetically into the **Government / municipal customers** section:

```
# --------------------------------------------------
# Government / municipal customers
# --------------------------------------------------
amadorgov.org                  OK
cityofsolanabeach.ca.gov        OK
cosb.org                       OK
...
```

> **NOTE:** The script preserves all section headers and other sections. Only the Government section is modified. Entries are inserted alphabetically by domain name.

---

## Region Selection

The region parameter determines which AWS region the SES identity is created in. Regardless of region, the domain is added to `relay_domains` on **both** relay servers for failover.

| Client Timezone | Region Parameter | SES Region | relay_domains Updated |
|-----------------|-----------------|------------|----------------------|
| Eastern | `east` | us-east-1 | Both relays |
| Central | `east` | us-east-1 | Both relays |
| Mountain | `west` | us-west-2 | Both relays |
| Pacific / Western | `west` | us-west-2 | Both relays |

---

## How to Add a New Client Domain

Run the `/smtp-add-client` skill from Claude Code:

```
/smtp-add-client clientdomain.gov west
/smtp-add-client clientdomain.gov east
```

| Parameter | Example | Description |
|-----------|---------|-------------|
| Domain | `cityofsolanabeach.ca.gov` | The client's email domain |
| Region | `west` | `east` = us-east-1 \| `west` = us-west-2 |

### What the Skill Does

**Step 1 — SES Identity:**
- Checks if the domain already has a verified identity in the specified SES region
- If already exists: reports current verification status and shows DKIM records if still pending
- If new: creates identity with Easy DKIM (RSA_2048_BIT, signatures enabled, Route53 publishing disabled)
- Saves DKIM records to a CSV file in your Downloads folder: `dkim-<domain>.csv`
- Displays DKIM records on screen

**Step 2 — Postfix relay_domains (both relays):**
- Retrieves `svc-wsl-relay` and `relayadmin` passwords from SSM Parameter Store
- Connects to each relay via SSM Run Command
- Opens a WinRM loopback PSSession as `cloud\svc-wsl-relay`
- Runs a Python script inside WSL (via sudo) to insert the domain alphabetically in the Government section
- Runs `postmap` to rebuild the hash database
- Reloads Postfix to apply changes
- Validates the entry with `postmap -q`
- Reports `ALREADY_PRESENT` if domain was already in the file — safe to re-run

### Output Examples

**New domain (SES identity created):**
```
=== Step 1: SES Identity (us-west-2) ===
  Identity created. Status: Verification pending
  DKIM CSV saved to: C:\Users\...\Downloads\dkim-clientdomain.gov.csv

=== Step 2: Postfix relay_domains (both relays) ===
  inf-relay001 (us-east-1): Added and validated OK.
  inf-relay101 (us-west-2): Added and validated OK.

=== Complete ===
  Domain 'clientdomain.gov' processed.
```

**Existing domain (SES identity already present):**
```
=== Step 1: SES Identity (us-west-2) ===
  Identity 'clientdomain.gov' already exists in us-west-2.
  Status: Verification pending
  Skipping SES creation - proceeding to relay update.
```

---

## After Running the Skill

### Send DKIM Records to Client

The client must add three DKIM CNAME records to their DNS before SES marks the identity as Verified. The CSV saved to your Downloads folder contains:

| Column | Example Value |
|--------|---------------|
| Name | `abc123._domainkey.clientdomain.gov` |
| Type | `CNAME` |
| Value | `abc123.dkim.amazonses.com` |

Send the CSV as an attachment in an encrypted email to the client.

### Verify SES Identity Status

Once the client confirms their DNS records are added:

```powershell
aws sesv2 get-email-identity --email-identity clientdomain.gov `
    --profile PALegacySharedServices --region us-west-2 `
    --query "VerifiedForSendingStatus" --output text
```

Expected result: `True`

---

## Technical Notes

### Why WinRM Loopback is Used

WSL cannot be run from the SYSTEM account (which SSM Run Command uses by default). To run WSL as `cloud\svc-wsl-relay`, the script opens a WinRM loopback PSSession using that account's credentials. This requires `LocalAccountTokenFilterPolicy = 1` in the registry, which is set on both relay servers.

### Why the sudo Password is Written to a Temp File

The `relayadmin` password contains special characters (`$`, `*`, etc.) that bash would expand if passed via `echo "password" | sudo -S`. Writing the password to a temp file (`C:\Windows\Temp\relay_sudo.tmp`) and using `cat file | sudo -S` avoids this. The temp file is deleted immediately after use.

### Why Entries Go in the Government Section Only

The `relay_domains` file is structured into named sections. New client domains are government/municipal customers by convention. The Python script locates the `# Government / municipal customers` section header, skips the two-line header block (title + closing dashes), and inserts the new domain alphabetically within that section. All other sections are left completely untouched.

### Script Location

```
scripts/smtp/Add-SmtpClient.ps1
.claude/skills/smtp-add-client/SKILL.md
```

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `SSM command failed: Access is denied` | `LocalAccountTokenFilterPolicy` not set on relay | Set `HKLM:\...\Policies\System\LocalAccountTokenFilterPolicy = 1` (DWORD) via SSM |
| `Failed to get svc-wsl-relay password` | SSM parameter missing in that region | Add `/relay/svc-wsl-relay` to Parameter Store in the affected region |
| `Failed to get relayadmin password` | SSM parameter missing in that region | Add `/relay/relayadmin` to Parameter Store in the affected region |
| `ERROR: Government section header not found` | `relay_domains` file structure changed | Section header must read exactly: `# Government / municipal customers` |
| `VALIDATE: (empty)` | postmap did not find the entry | Check `relay_domains` file manually; postmap may need to be rerun |
| SES create failed | Domain already exists in wrong region or quota issue | Check SES console; delete and recreate in correct region if needed |
