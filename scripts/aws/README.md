# scripts/aws — AWS EC2 / SSM

Python and PowerShell automation for the CloudOps Windows fleet (both Foundation and Legacy orgs). All tools use AWS SSM — no direct SSH/WinRM.

**Pre-requisite:** run `Setup: Sync AWS Config` then `Setup: AWS SSO Login (foundation)` and/or `Setup: AWS SSO Login (legacy)` before using any of these tools. See [`aws-configs/README.md`](../../aws-configs/README.md).

---

## Quick start — RDP to a server

```powershell
# From CLI (account name is fuzzy-matched against accounts.json)
.\Connect-RDP.ps1 -ServerName INF-PLOGIC018 -Account PALegacyPlus
.\Connect-RDP.ps1 -s CLD-PPLSAPM001 -a PLUS   # prompts if "PLUS" matches multiple accounts

# Or use the Kiro task: AWS: RDP to Instance
```

---

## Tools

### Connection helpers (PowerShell)

| Script | Kiro Task | Purpose |
|--------|-----------|---------|
| `Connect-RDP.ps1` | `AWS: RDP to Instance` | Port-forward RDP via SSM and auto-launch mstsc |
| `connect-instance.ps1` | `AWS: Connect to Instance` | Open an interactive SSM shell session |
| `Find-Instance.ps1` | *(utility)* | Resolve a server Name tag → instance ID across priority regions |

### Operations scripts (Python — GUI picker or `--account` flag)

| Script / Folder | Kiro Task | Purpose |
|-----------------|-----------|---------|
| `disk-expand/expand_disk.py` | `AWS: Expand Disk` | Expand an EBS volume and resize the OS partition via SSM |
| `disk-expand/expand_disk_lm.py` | `AWS: Expand Disk (LM)` | Same, but parses the server/drive from a pasted LogicMonitor alert |
| `rds-license-reset/` | `AWS: Reset RDS License Grace Period` | Reset the RDS 120-day grace period via SSM |
| `server-reboot/` | `AWS: Reboot Server` | Reboot an EC2 instance via SSM with health-check wait |
| `service-restart/` | `AWS: Restart Service` | Restart a Windows service via SSM |
| `site-monitor/investigate.py` | `AWS: Investigate Site` | Investigate a site outage / IIS status via SSM |
| `site-monitor/investigate_recycle_fix.py` | `AWS: Investigate Site (Recycle Fix)` | Diagnose and fix IIS app pool memory/recycle issues via SSM |

### Internal shared module

| File | Purpose |
|------|---------|
| `aws_sso_helper.py` | Shared SSO helpers used by all Python scripts: `resolve_account()`, `ensure_profile_session()`, `pick_profile_gui()`. Also exposes a CLI for PowerShell callers: `python aws_sso_helper.py resolve --name <NAME>` |
| `fetch_foundation_ous.py` | List accounts accessible via an SSO session. Run directly: `python fetch_foundation_ous.py --account PLUS` |

---

## Account names (fuzzy matching)

All tools accept informal account names. Matching is: exact → case-insensitive → **nickname** (1:1) → **application** (1:many) → substring → token overlap. If a name matches more than one account you will be asked to choose. Nicknames and applications are defined in [`aws-configs/aliases.json`](../../aws-configs/README.md#account-aliases--nicknames-vs-applications).

```powershell
# These all resolve to PALegacyPlus (939845564306):
-Account PALegacyPlus
-Account palegacyplus
-Account PLUS          # substring match — prompts if PALegacyPlusDev also matches
```

The account registry lives in [`aws-configs/accounts.json`](../../aws-configs/README.md). Regenerate monthly or when accounts change:
```
python aws-configs/tools/generate_aws_config.py
```

---

## SSO session management

Scripts automatically detect whether the account belongs to the `foundation` or `legacy` SSO session and trigger the correct `aws sso login` when needed. You do not need to know which org an account is in.

---

## Priority regions

When no region is specified, scripts search `us-east-1` → `us-west-2` → `ca-central-1` in that order and stop at the first hit.
