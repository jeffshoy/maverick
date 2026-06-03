# scripts/aws — AWS EC2 / SSM

Python and PowerShell automation for the Foundation OU Windows fleet. All tools use AWS SSM — no direct SSH/WinRM.

**Pre-requisite:** run `Setup: AWS SSO Login (foundation)` (or `legacy`) before any of these tools. See [`aws-configs/README.md`](../../aws-configs/README.md).

## Tools

| Script / Folder | Kiro Task | Purpose |
|-----------------|-----------|---------|
| `connect-instance.ps1` | `AWS: Connect to Instance` | Open an interactive SSM session to any server |
| `disk-expand/` | `AWS: Expand Disk` | Expand an EC2 Windows disk via SSM |
| `rds-license-reset/` | `AWS: Reset RDS License Grace Period` | Reset the RDS 120-day grace period via SSM |
| `server-reboot/` | `AWS: Reboot Server` | Reboot an EC2 instance via SSM |
| `service-restart/` | `AWS: Restart Service` | Restart a Windows service via SSM |
| `site-monitor/` | `AWS: Investigate Site` | Investigate a site outage / IIS issue |
| `fetch_foundation_ous.py` | *(run directly)* | List Foundation OU accounts from SSO — see `aws-configs/tools/generate_aws_config.py` |

## connect-instance.ps1

```powershell
# Open an SSM session (profile defaults to PALegacySharedServices, region to us-east-1)
.\connect-instance.ps1 -server_name ARCT-PTRKRD001
.\connect-instance.ps1 -server_name ARCT-PTRKRD001 -aws_region us-west-2
.\connect-instance.ps1 -server_name ARCT-PTRKRD001 -aws_profile PALegacyFinEntANCO
```

The script checks your SSO session and triggers `aws sso login --sso-session foundation` automatically if expired.
