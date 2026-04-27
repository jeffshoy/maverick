# RDS License Grace Period Reset Tool

Resets Terminal Server (RDS) grace licensing period to 120 days on remote EC2 instances via AWS SSM.

---

## Prerequisites

- **Python 3.8+** with `boto3` (`pip install boto3`)
- **AWS CLI v2** installed
- **SSM Agent** running on target EC2 instances
- Your user must have the `cst-comm-cloudadmin` role in the `PALegacySharedServices` account (361362055558)

---

## Setup (one-time)

### 1. AWS Config — DONE
The `PALegacySharedServices` profile has been added to `~/.aws/config`.

### 2. Install boto3
```
pip install boto3
```

### 3. SSO Login
```
aws sso login --sso-session foundation
```
Opens your browser → log in → authorize. The scripts auto-trigger this if the session expires.

### 4. Create SSM Document in AWS (auto or manual)

**Option A — Automatic:** Just run `python rds_license_reset.py`. It creates the document automatically in whichever region(s) you pick.

**Option B — Manual:**
```
aws ssm create-document --name "Reset-RDSGracePeriod" --document-type "Command" --document-format "JSON" --content file://ssm-doc.json --profile PALegacySharedServices --region us-east-1

aws ssm create-document --name "Reset-RDSGracePeriod" --document-type "Command" --document-format "JSON" --content file://ssm-doc.json --profile PALegacySharedServices --region us-west-2
```

### 5. Verify SSM Agent on target EC2s
The TRKRD servers must have SSM Agent installed and an IAM instance profile with `AmazonSSMManagedInstanceCore` policy. Check:
```
aws ssm describe-instance-information --profile PALegacySharedServices --region us-east-1
```
If your TRKRD servers don't show up, SSM Agent isn't configured on them.

---

## Usage

### Reset RDS License (main tool)
```
cd C:\Users\sunil.kanakappagari\rds-license-reset
python rds_license_reset.py
```

Flow:
1. Checks SSO → opens browser if expired
2. Enter client code (e.g. `ARCT`)
3. Pick region: `E` (us-east-1), `W` (us-west-2), or Enter (both)
4. Shows matching EC2 instances (e.g. `ARCT-PTRKRD001`)
5. Select by number (comma-separated: `1,2,3`)
6. Runs the reset → force reboots → pings until online → verifies license

### Connect to a Foundation server (SSM session)
```
.\connectto_foundation.ps1 -s ARCT-PTRKRD001
.\connectto_foundation.ps1 -s ARCT-PTRKRD001 -r us-west-2
.\connectto_foundation.ps1 -s ARCT-PTRKRD001 -p PALegacyFinEntANCO
```

---

## Files

| File | Where | Purpose |
|------|-------|---------|
| `~/.aws/config` | Already updated | Has `PALegacySharedServices` profile |
| `rds_license_reset.py` | Run from your machine | Main CLI tool |
| `connectto_foundation.ps1` | Run from your machine | SSM connect helper |
| `ssm-doc.json` | Used once to create SSM doc | SSM document definition |
| `Reset-RDSGracePeriod.ps1` | Reference only | Standalone PS1 (embedded in ssm-doc.json) |
| `aws-configs/config_Foundation` | Reference only | All Foundation OU profiles for future use |

---

## What gets created in AWS

| Resource | Region(s) | Account | Description |
|----------|-----------|---------|-------------|
| SSM Document `Reset-RDSGracePeriod` | us-east-1 + us-west-2 | 361362055558 (PALegacySharedServices) | The PowerShell script that resets the registry key and reboots |

That's it. No Lambda, no EC2, no IAM roles to create. Just one SSM document per region.
