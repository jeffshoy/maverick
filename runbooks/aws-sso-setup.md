# AWS SSO Setup

## When to use

- First-time setup for a new team member
- After AWS org changes (new accounts added, accounts migrated between orgs)
- When `aws sso login` returns an error about an unknown session or missing profile
- After pulling a `cloudops.config` update and needing to sync `~/.aws/config`

---

## Pre-checks

- [ ] AWS CLI v2 installed: `aws --version` should show `aws-cli/2.x.x`
- [ ] Python 3.10+ installed: `python --version`
- [ ] `boto3` installed: `pip install boto3` (required by `generate_aws_config.py` and all Python scripts)
- [ ] SSM Session Manager plugin installed (required for `Connect-RDP.ps1` and `connect-instance.ps1`): [install guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- [ ] RSAT ActiveDirectory module installed (required for AD scripts only)

---

## Procedure

### 1. Clone the repo and set up CLAUDE.md

```powershell
cd C:\repos
git clone https://psgov@dev.azure.com/psgov/Cloud-PA/_git/cloudops
```

**Option A — Symlink (preferred, auto-updates on `git pull`):**
```powershell
# Run from an elevated PowerShell prompt or with Windows Developer Mode enabled
New-Item -ItemType SymbolicLink `
    -Path "$env:USERPROFILE\.claude\CLAUDE.md" `
    -Target "C:\repos\cloudops\CLAUDE.md"
```

**Option B — Copy (no admin required, re-run after updates):**
```powershell
Copy-Item C:\repos\cloudops\CLAUDE.md "$env:USERPROFILE\.claude\CLAUDE.md"
```

### 2. Sync the AWS config

Run in Kiro: **`Setup: Sync AWS Config`**

Or from CLI:
```powershell
cd C:\repos\cloudops
pwsh aws-configs/tools/Sync-AwsConfig.ps1
```

This merges `aws-configs/cloudops.config` (451+ accounts, both Foundation and Legacy orgs) into `~/.aws/config`, preserving any personal profiles you have. A timestamped backup is written before any changes.

Run with `-WhatIf` to preview changes without writing.

### 3. Authenticate — Foundation SSO

Run in Kiro: **`Setup: AWS SSO Login (foundation)`**

Or from CLI:
```
aws sso login --sso-session foundation
```

A browser window will open. Sign in with your CentralSquare credentials. The session covers all Foundation-org profiles (role: `cst-comm-cloudadmin`).

**Verify:**
```
aws sts get-caller-identity --profile PALegacySharedServices
```
Expected: `"Account": "361362055558"`

### 4. Authenticate — Legacy SSO

Run in Kiro: **`Setup: AWS SSO Login (legacy)`**

Or from CLI:
```
aws sso login --sso-session legacy
```

The session covers all Legacy-org profiles (role: `Cloud-Administrator`).

**Verify:**
```
aws sts get-caller-identity --profile legacy-<any-legacy-account>
```

### 5. Regenerate the account list (monthly or on missing-account error)

If you hit a "No account found matching" error, the account registry may be stale.

```powershell
cd C:\repos\cloudops
python aws-configs/tools/generate_aws_config.py
```

This re-queries both SSO orgs, regenerates `aws-configs/cloudops.config` and `aws-configs/accounts.json`, then submit a PR with the updated files. After merge, teammates re-run Step 2.

---

## Verification

```powershell
# Foundation
aws sts get-caller-identity --profile PALegacySharedServices
# Expected: "Account": "361362055558"

# Legacy (substitute any legacy profile name from cloudops.config)
aws sts get-caller-identity --profile legacy-<name>
```

Test an actual operation:
```powershell
pwsh scripts/aws/Connect-RDP.ps1 -ServerName <any-known-server> -Account PALegacySharedServices -NoLaunch
# Expected: tunnel opens, prints localhost:33389, exits cleanly
```

---

## Rollback

If `Sync-AwsConfig.ps1` broke your personal `~/.aws/config`:

```powershell
# List available backups
ls $HOME/.aws/config.backup-*

# Restore the most recent backup
Copy-Item "$HOME\.aws\config.backup-<timestamp>" "$HOME\.aws\config"
```

---

## Related

- [`aws-configs/README.md`](../aws-configs/README.md) — full detail on the two SSO sessions and the config file format
- [`scripts/aws/README.md`](../scripts/aws/README.md) — all AWS tools and account name fuzzy-matching
