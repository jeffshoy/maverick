# RDS License Grace Period Reset Tool

Resets Terminal Server (RDS) grace licensing period to 120 days on remote EC2 instances via AWS SSM.

---

## Prerequisites

- **Python 3.8+** with `boto3` (`pip install boto3`)
- **AWS CLI v2** installed
- **SSM Agent** running on target EC2 instances
- Your user must have the `cst-comm-cloudadmin` role in the target AWS account

---

## Setup (one-time)

### 1. AWS Config
Ensure your `~/.aws/config` has Foundation OU profiles with `sso_session = foundation`.
Run the **`Setup: Sync AWS Config`** Kiro task (see repo root `README.md`) or see `aws-configs/cloudops.config` for reference.

### 2. Install boto3
```
pip install boto3
```

### 3. SSO Login
```
aws sso login --sso-session foundation
```
Opens your browser → log in → authorize. The script auto-triggers this if the session expires.

---

## Usage

### Reset RDS License (main tool)
```
cd C:\Users\sunil.kanakappagari\Foundation\RDS-license-reset
python rds_license_reset.py
```

Flow:
1. GUI popup — searchable dropdown to pick the AWS OU (reads all `foundation` profiles from `~/.aws/config`)
2. SSO login — opens browser if expired
3. Enter client code (e.g. `ARCT`) or server name wildcard (e.g. `ARCT-PTRKRD` or just `TRKRD`)
4. Pick region: `E` (us-east-1), `W` (us-west-2), or Enter (both)
5. Shows matching EC2 instances
6. Select by number (comma-separated: `1,2,3`)
7. **Checks current grace period** on each selected instance:
   - If grace period is **0** (expired) → auto-queued for reset
   - If grace period is **> 0** → asks if you want to apply the reset (Y/N)
   - If grace period **cannot be determined** → asks if you want to proceed anyway
8. Final confirmation before executing
9. Runs the reset → force reboots → pings until online → verifies license
10. Option to search again, switch OU, or exit

### Connect to a Foundation server (SSM session)
```
..\connect-instance.ps1 -s ARCT-PTRKRD001
..\connect-instance.ps1 -s ARCT-PTRKRD001 -r us-west-2
..\connect-instance.ps1 -s ARCT-PTRKRD001 -p PALegacyFinEntANCO
```

---

## Files

| File | Purpose |
|------|---------|
| `rds_license_reset.py` | Main CLI tool — OU picker, wildcard search, grace check, reset |
| `../connect-instance.ps1` | SSM connect helper |
| `ssm-doc.json` | SSM document definition (reference) |
| `Reset-RDSGracePeriod.ps1` | Standalone PS1 (reference — embedded in ssm-doc.json) |
| `../../../aws-configs/cloudops.config` | All team AWS profiles (both SSO sessions) |
| `requirements.txt` | Python dependencies |

---

## What gets created in AWS

| Resource | Region(s) | Description |
|----------|-----------|-------------|
| SSM Document `Reset-RDSGracePeriod` | us-east-1 + us-west-2 | PowerShell script that resets the registry key and reboots |

The SSM document is auto-created in whichever region(s) you select when running the tool.
