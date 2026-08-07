# CZP NaviLine — Windows Server 2022 AMI Build

## Overview

This document covers building a golden Windows Server 2022 AMI for deploying new
NaviLine CZP (Citizen Zone Portal / Click2Gov) cloud clients. The AMI includes all
base prerequisites so that per-client deployments only need client-specific configuration.

**Two AMIs will be created:**
- us-east-1 (east)
- us-west-2 (west)

**Product:** NaviLine CZP (Click2Gov)
**First Client:** AUGU (Eastern Time Zone)

---

## Account Details

| | East (us-east-1) | West (us-west-2) |
|--|-------------------|-------------------|
| **Account** | PALegacyCzp — 797320052894 | PALegacyCzp — 797320052894 |
| **AWS Profile** | `PALegacyCzp` | `PALegacyCzp` |
| **Region** | us-east-1 | us-west-2 |
| **VPC** | `vpc-0b2035fbd41f0db42` | `vpc-002a89c20120a13ad` |
| **Subnet** | `subnet-02d80aaf16530a61a` | `subnet-0cf42f971f9e295cd` |
| **Security Group** | `sg-0ac3d45578e28d2c7` | `sg-02ef98a1b1b18e2d4` |
| **IAM Instance Profile** | `EC2-Default-SSM-AD-Role` | `EC2-Default-SSM-AD-Role` |
| **Instance Type** | m6a.large | m6a.large |
| **Key Pair** | `czp-naviline-ami-build` | `czp-naviline-ami-build` |
| **Base AMI** | Windows Server 2022 Full (latest from AWS) | Windows Server 2022 Full (latest from AWS) |
| **Root Volume (C:)** | 80 GB gp3, encrypted | 80 GB gp3, encrypted |
| **Data Volume (D:)** | 60 GB gp3, encrypted (`/dev/sdb`) | 60 GB gp3, encrypted (`/dev/sdb`) |

---

## Prerequisites

- Access to AWS SSO: https://d-9067f93f22.awsapps.com/start/#/
- Access to Netbox: https://netbox.aspgov.com/
- Access to Azure DNS (aspgov.com zone)
- Access to Salesforce for RFC creation
- ASPGOV domain admin credentials
- Access to aspgov.pri domain controller (ADUC)
- Access to SecureLink: https://securelink.aspgov.com/rss-servlet/signon.action

---

## Naming Convention

CZP NaviLine servers follow this pattern:

| Environment | Pattern | Example (AUGU) |
|-------------|---------|----------------|
| Test | `{CLIENT}-TC2GWB001` | `AUGU-TC2GWB001` |
| Prod | `{CLIENT}-PC2GWB001` | `AUGU-PC2GWB001` |

---

## Phase 1 — Launch Base Instance

### East (us-east-1)

```powershell
# Base AMI: ami-0ed0165f19a049904 (Windows_Server-2022-English-Full-Base-2026.07.15)

aws ec2 run-instances --profile PALegacyCzp --region us-east-1 `
  --image-id ami-0ed0165f19a049904 `
  --instance-type m6a.large `
  --subnet-id subnet-02d80aaf16530a61a `
  --security-group-ids sg-0ac3d45578e28d2c7 `
  --iam-instance-profile Name=EC2-Default-SSM-AD-Role `
  --key-name czp-naviline-ami-build `
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":80,"VolumeType":"gp3","Encrypted":true}},{"DeviceName":"/dev/sdb","Ebs":{"VolumeSize":60,"VolumeType":"gp3","Encrypted":true}}]' `
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=czp-naviline-ami-build-use1},{Key=Purpose,Value=AMI-Build}]' `
  --output json
```

### West (us-west-2)

```powershell
# Base AMI: ami-037613a54b9f6541a (Windows_Server-2022-English-Full-Base-2026.07.15)

aws ec2 run-instances --profile PALegacyCzp --region us-west-2 `
  --image-id ami-037613a54b9f6541a `
  --instance-type m6a.large `
  --subnet-id subnet-0cf42f971f9e295cd `
  --security-group-ids sg-02ef98a1b1b18e2d4 `
  --iam-instance-profile Name=EC2-Default-SSM-AD-Role `
  --key-name czp-naviline-ami-build `
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":80,"VolumeType":"gp3","Encrypted":true}},{"DeviceName":"/dev/sdb","Ebs":{"VolumeSize":60,"VolumeType":"gp3","Encrypted":true}}]' `
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=czp-naviline-ami-build-usw2},{Key=Purpose,Value=AMI-Build}]' `
  --output json
```

### Key Pairs

Created in both regions with name `czp-naviline-ami-build`:
- East PEM: `$env:USERPROFILE\.ssh\czp-naviline-ami-build-use1.pem`
- West PEM: `$env:USERPROFILE\.ssh\czp-naviline-ami-build-usw2.pem`

Note the instance IDs from the output.

---

## Phase 2 — Connect via SSM

```powershell
# East
aws ssm start-session --profile PALegacyCzp --region us-east-1 --target <INSTANCE_ID>

# West
aws ssm start-session --profile PALegacyCzp --region us-west-2 --target <INSTANCE_ID>

# For RDP access (port forwarding through SSM):
aws ssm start-session --profile PALegacyCzp --region us-east-1 --target <INSTANCE_ID> `
  --document-name AWS-StartPortForwardingSession `
  --parameters "portNumber=3389,localPortNumber=33389"
# Then RDP to localhost:33389
```

---

## Phase 3 — Server Prerequisites (RDP into instance)

These steps are performed manually via RDP. The AMI build instance does NOT need
a static IP or domain join — those happen per-client at deploy time.

### 3.1 Install Security Tools

Install the required security agents per organizational policy:
- Tanium

### 3.2 Install Windows Features

Open PowerShell as Administrator:

```powershell
# Install required Windows features for CZP/NaviLine
# .NET Framework 3.5 (required by some NaviLine components)
Install-WindowsFeature -Name NET-Framework-Features -IncludeAllSubFeature

# .NET Framework 4.8 (should already be present on Server 2022)
# Verify:
Get-WindowsFeature NET-Framework-45-Features

# Web Server (IIS) — installed but will be DISABLED after configuration
Install-WindowsFeature -Name Web-Server -IncludeManagementTools -IncludeAllSubFeature
```

### 3.3 Disable IIS

IIS is installed for its management tools / dependencies but should not be running:

```powershell
# Stop and disable IIS
Stop-Service -Name W3SVC -Force
Set-Service -Name W3SVC -StartupType Disabled

Stop-Service -Name WAS -Force
Set-Service -Name WAS -StartupType Disabled

# Verify IIS is stopped
Get-Service W3SVC, WAS | Select-Object Name, Status, StartType
```

### 3.4 Configure D: Drive (Data Volume)

The D: drive is used for application data (Apache, Tomcat, etc. installed per-client
at deploy time by the dev team):

```powershell
# Initialize and format the D: drive
Get-Disk | Where-Object PartitionStyle -eq 'RAW' | `
  Initialize-Disk -PartitionStyle GPT -PassThru | `
  New-Partition -DriveLetter D -UseMaximumSize | `
  Format-Volume -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
```

---

## Phase 4 — Cleanup (Pre-AMI / Sysprep)

### 4.1 Clean Up Temp Files

```powershell
# Clear temp directories
Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Users\Administrator\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clear Windows Update cache
Stop-Service -Name wuauserv -Force
Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Start-Service -Name wuauserv

# Clear event logs
wevtutil cl Application
wevtutil cl Security
wevtutil cl System
```

### 4.2 Run EC2Launch v2 Sysprep

```powershell
# EC2Launch v2 is pre-installed on Windows Server 2022 AMIs from AWS
# Run Sysprep to generalize the image
& "C:\Program Files\Amazon\EC2Launch\EC2Launch.exe" sysprep --shutdown
```

**Important:** This will shut down the instance. Do NOT start it again — create the
AMI from the stopped state.

---

## Phase 5 — Create AMI (from your workstation)

### East (us-east-1)

```powershell
# Wait for instance to be stopped (after sysprep shutdown)
aws ec2 wait instance-stopped --profile PALegacyCzp --region us-east-1 --instance-ids <INSTANCE_ID>

# Create the AMI
$datestamp = Get-Date -Format "yyyyMMdd"
aws ec2 create-image --profile PALegacyCzp --region us-east-1 `
  --instance-id <INSTANCE_ID> `
  --name "czp-naviline-win2022-use1-v1.0-$datestamp" `
  --description "CZP NaviLine | Windows Server 2022 | us-east-1 | Base golden AMI" `
  --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=czp-naviline-win2022-use1},{Key=Version,Value=1.0},{Key=Owner,Value=CloudOps},{Key=OS,Value=Windows-Server-2022},{Key=Region,Value=us-east-1},{Key=Purpose,Value=CZP-NaviLine},{Key=Product,Value=NaviLine}]" "ResourceType=snapshot,Tags=[{Key=Name,Value=czp-naviline-win2022-use1-snapshot}]"

# Wait for AMI to become available
aws ec2 wait image-available --profile PALegacyCzp --region us-east-1 --image-ids <AMI_ID>
```

### West (us-west-2)

```powershell
aws ec2 wait instance-stopped --profile PALegacyCzp --region us-west-2 --instance-ids <INSTANCE_ID>

$datestamp = Get-Date -Format "yyyyMMdd"
aws ec2 create-image --profile PALegacyCzp --region us-west-2 `
  --instance-id <INSTANCE_ID> `
  --name "czp-naviline-win2022-usw2-v1.0-$datestamp" `
  --description "CZP NaviLine | Windows Server 2022 | us-west-2 | Base golden AMI" `
  --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=czp-naviline-win2022-usw2},{Key=Version,Value=1.0},{Key=Owner,Value=CloudOps},{Key=OS,Value=Windows-Server-2022},{Key=Region,Value=us-west-2},{Key=Purpose,Value=CZP-NaviLine},{Key=Product,Value=NaviLine}]" "ResourceType=snapshot,Tags=[{Key=Name,Value=czp-naviline-win2022-usw2-snapshot}]"

aws ec2 wait image-available --profile PALegacyCzp --region us-west-2 --image-ids <AMI_ID>
```

---

## Phase 6 — Record AMI IDs

### Pre-Sysprep Checkpoint AMIs

Use these to revert if you need to make changes after sysprep. Launch a new instance
from the checkpoint AMI, make your changes, then re-sysprep.

| Region | AMI ID | Name |
|--------|--------|------|
| us-east-1 | `ami-04d208a152789fce4` | czp-naviline-pre-sysprep-use1 |
| us-west-2 | `ami-042ce43cdf8c0946d` | czp-naviline-pre-sysprep-usw2 |

### Golden AMIs (Post-Sysprep — Final)

| Region | AMI ID | Name | Date |
|--------|--------|------|------|
| us-east-1 | `ami-064b29edcf57c4d89` | czp-naviline-win2022-use1-v1.1-20260805 | 2026-08-05 |
| us-west-2 | `ami-02490a181d0051837` | czp-naviline-win2022-usw2-v1.1-20260805 | 2026-08-05 |

### Launch Templates

| Region | Template ID | Name |
|--------|-------------|------|
| us-east-1 | `lt-0835492de97e6e968` | czp-naviline-use1 |
| us-west-2 | `lt-0f44a807767fb1341` | czp-naviline-usw2 |

**Tags included in launch template:**

| Tag Key | Value |
|---------|-------|
| `cst_application` | `web_server` |
| `cst_tenancy` | `single` |
| `cst_backup_policy` | `prod` |
| `DataDog` | `enabled` |
| `CloudWatchAgent` | `enabled` |
| `cst_environment` | `prd` |
| `cst_compliance_domain` | `pci` |
| `cst_product_line` | `pa_citizenengagement` |

---

## Post-AMI: Client Deployment Process

Once the golden AMI is built, deploying a new NaviLine CZP client follows this process:

### Pre-Provisioning (per client)

1. **IPAM Reservation** — Reserve IP address in Netbox for the client's server
2. **Internal DNS** — Create A record: `{CLIENT}-{ENV}C2GWB001.aspgov.pri` → reserved IP
3. **External DNS** — Create A record in Azure DNS (aspgov.com zone) if external access needed
4. **RFC** — Create RFC in Salesforce

### Server Provisioning

1. Launch instance from launch template with the reserved IP
2. Connect via SSM / RDP
3. Set computer name: `{CLIENT}-{ENV}C2GWB001`
4. Domain join to `aspgov.pri`
5. Move computer object to appropriate OU in ADUC
6. Apply group memberships (`WSUS_PROD_2AM_GROUP`, `Apply_Schannel_TLS1_2_Enabled`)
7. Run `gpupdate /force` — proxy config (baked into AMI) is applied via GPO once domain-joined
8. Hand off to dev team for application install (Java, Apache, Tomcat, WAR files)
9. Validate

### Region Selection

| Client Timezone | AWS Region |
|-----------------|------------|
| Eastern / Central | us-east-1 |
| Mountain / Western (Pacific) | us-west-2 |

**AUGU** = Eastern Time → **us-east-1**

---

## Software Inventory (What's on the AMI)

| Component | Version | Purpose |
|-----------|---------|---------|
| Windows Server | 2022 Full | Base OS |
| .NET Framework | 3.5 + 4.8 | Application dependencies |
| IIS | Installed, DISABLED | Management tools / dependencies only |
| SSM Agent | (pre-installed) | AWS Systems Manager access |
| Security tools | Per policy | Tanium, Rapid7, etc. |
| D: drive | 60 GB gp3, formatted NTFS | Pre-provisioned for app data (Apache/Tomcat installed per-client) |

---

## Build Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-08-04 | East build instance launched | `i-0b73deca87809f3d8` (172.30.12.13) |
| 2026-08-04 | West build instance launched | `i-0c3221f9191cde819` (172.29.12.106) |
| 2026-08-04 | Key pairs created | `czp-naviline-ami-build` in both regions |
| 2026-08-04 | Proxy configured | East: 172.30.20.55:8080, West: 172.29.20.55:8080 |
| 2026-08-04 | Security tools installed | |
| 2026-08-05 | IIS disabled | W3SVC + WAS set to Disabled |
| 2026-08-05 | Pre-sysprep checkpoint AMIs created | East: `ami-04d208a152789fce4`, West: `ami-042ce43cdf8c0946d` |
| 2026-08-05 | Sysprep run | `& "C:\Program Files\Amazon\EC2Launch\EC2Launch.exe" sysprep --shutdown` |
| 2026-08-05 | Golden AMIs v1.0 created | East: `ami-0af8d3152ed935880`, West: `ami-0ac289b32cfda15b2` (DEREGISTERED — missing D: drive) |
| 2026-08-05 | Launched v2 build from golden AMI | East: `i-01b801b0c00de90d8`, West: `i-0257c88bf168696c9` |
| 2026-08-05 | D: drive provisioned + sysprep | 60 GB gp3, NTFS, label "Data" |
| 2026-08-05 | Golden AMIs v1.1 created | East: `ami-064b29edcf57c4d89`, West: `ami-02490a181d0051837` |
| 2026-08-05 | Old golden AMIs deregistered + snapshots deleted | v1.0 AMIs removed |
| 2026-08-05 | Launch templates updated to v1.1 AMIs | Default version set to 2 |
