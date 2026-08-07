# CZP NaviLine — New Client Deployment Runbook

## Overview

This runbook covers the end-to-end process for deploying a new NaviLine CZP
(Click2Gov / Citizen Zone Portal) client server in AWS from the golden AMI.

**AWS Account:** PALegacyCzp — 797320052894
**AWS Profile:** `PALegacyCzp`

**Golden AMIs:**
- us-east-1: `ami-064b29edcf57c4d89`
- us-west-2: `ami-02490a181d0051837`

**Launch Templates:**
- us-east-1: `lt-0835492de97e6e968` (czp-naviline-use1)
- us-west-2: `lt-0f44a807767fb1341` (czp-naviline-usw2)

---

## Prerequisites

- Access to AWS SSO: https://d-9067f93f22.awsapps.com/start/#/
- Access to Netbox: https://netbox.aspgov.com/
- Access to Azure DNS (aspgov.com zone)
- Access to Salesforce for RFC creation
- ASPGOV domain admin credentials
- Access to aspgov.pri domain controller (ADUC)
- Access to SecureLink: https://securelink.aspgov.com/rss-servlet/signon.action
- Access to F5 BIG-IP (Voorhees: `10.0.30.33`/`10.0.30.34`; Vegas: `10.0.60.33`/`10.0.60.34`)

---

## Naming Convention

| Environment | Pattern | Example (AUGU) |
|-------------|---------|----------------|
| Test | `{CLIENT}-TC2GWB001` | `AUGU-TC2GWB001` |
| Prod | `{CLIENT}-PC2GWB001` | `AUGU-PC2GWB001` |

---

## Region Selection

| Client Timezone | AWS Region | Launch Template |
|-----------------|------------|-----------------|
| Eastern / Central | us-east-1 | `lt-0835492de97e6e968` |
| Mountain / Western (Pacific) | us-west-2 | `lt-0f44a807767fb1341` |

---

## Before You Start: Netbox Reservation + RFC (Required First — Both Paths)

These two steps must be done manually before starting either the automated or manual deployment path — neither path does this for you.

### Step 1: Reserve IP Address in Netbox

Go to [Netbox](https://netbox.aspgov.com/) → IPAM → Prefixes

| Region | Prefix |
|--------|--------|
| us-east-1 | 172.30.12.0/24 |
| us-west-2 | 172.29.12.0/24 |

Find the next available IP above .20 and create the reservation with:
- Description: `{CLIENT}-{ENV}C2GWB001`
- Status: Active
- Tenant: (client name)

### Step 2: Create RFC in Salesforce

Create an RFC in Salesforce with:
- AWS account: PALegacyCzp (797320052894)
- Client name, client code, state, timezone
- Server name and IP
- Region

See [RFC-37896](https://centralsquare.lightning.force.com/lightning/r/RequestForChange__c/a8caZ000000ZkHhQAK/view) as a worked example to follow for field values and formatting.

---

## Automated Deployment (Preferred)

Use the `/czp-naviline-provision` Claude Code skill to automate the server build and network config: EC2 launch, domain join, AD OU/group placement, gpupdate/reboot, and DNS records (internal + public). This is **not** fully end-to-end — Netbox/RFC (above), SecureLink, and the F5 BIG-IP WAF config (Phase 6) are always manual, regardless of whether you use this skill or the manual path below.

**Prerequisites (one-time, already completed for this account):**
- `ASPGOV\svc-czp-navi-prov` service account exists with delegated rights on `aspgov.pri/C2G` and the two AD groups below
- Its password is stored as an SSM SecureString parameter in both AWS accounts/regions
- AWS CLI v2 is installed on the AD domain controllers used for this automation

**Invocation:**

```
/czp-naviline-provision {CLIENT} {PRIVATE_IP} {east|west} [Prod|Test] [PUBLIC_IP]
```

Example:
```
/czp-naviline-provision AUGU 172.30.12.24 east Prod 192.88.54.57
```

**What it does automatically:**
1. Launches the EC2 instance from the golden launch template with the given IP (from Step 1 above) and tags
2. Renames the computer and domain-joins it directly into `aspgov.pri/C2G` (three-tier fallback: `Add-Computer` → `djoin.exe` offline join → manual RDP prompt as last resort)
3. Confirms domain join, then applies `WSUS_PROD_2AM_GROUP` and `Apply_Schannel_TLS1_2_Enabled` group membership
4. Runs `gpupdate /force` and reboots
5. Creates all 3 DNS record types (see "DNS Records" under Phase 1 below for exactly what gets created)
6. Reports a summary of what succeeded

**Always manual, regardless of which path you use — not automated by this or any skill:**
- Netbox reservation and RFC creation (Steps 1-2 above) — done *before* running the skill
- SecureLink entry (Phase 5.1) and final RFC update (Phase 5.2) — done *after* the skill completes
- F5 BIG-IP WAF configuration (Phase 6) — done *after* the skill completes

**If Claude Code isn't available, or the automation fails partway through:** follow the manual steps below starting from wherever the automation left off. The automation's final summary states which steps succeeded — pick up from the first failed/incomplete step rather than restarting from scratch.

---

## Manual Deployment (Fallback)

Follow this section if Claude Code / the `/czp-naviline-provision` skill is unavailable, or if the automation fails partway through and you need to finish a step by hand. Phase numbers match what the automation does internally, so you can jump to the specific phase that failed. Steps 1-2 (Netbox reservation, RFC) above must already be done.

### Phase 1: Pre-Provisioning — DNS Records

The automation creates all 3 of these; if doing this manually, create them in this order.

**1. Internal DNS (aspgov.pri) — Host A record**

Create on the AD domain controller (via `dnsmgmt.msc` or `Add-DnsServerResourceRecordA`), zone `aspgov.pri`:

| Type | Record | Value |
|------|--------|-------|
| Host A | `{CLIENT}-{ENV}C2GWB001.aspgov.pri` | Reserved internal (private) IP |

This record is usually auto-created via dynamic DNS once the server is domain-joined (Phase 3.3) — check first before creating it manually to avoid a duplicate/conflicting record.

**2. Internal DNS (aspgov.com zone) — 2 CNAME records**

Create on `inf-svrdns001.cloud.lcl` (via `dnsmgmt.msc` or `Add-DnsServerResourceRecordCName`), zone `aspgov.com`:

| Type | Record | Value |
|------|--------|-------|
| CNAME | `{client_lowercase}-egov.aspgov.com` | `{CLIENT}-{ENV}C2GWB001.aspgov.pri` |
| CNAME | `s-{client_lowercase}-egov.aspgov.com` | `{CLIENT}-{ENV}C2GWB001.aspgov.pri` |

Both CNAMEs are always created together — there is no case where only one exists.

**3. Public DNS (Azure DNS — aspgov.com zone) — Host A record**

Create via the [Azure Portal](https://portal.azure.com) → DNS zones → `aspgov.com` → `+ Record set` (subscription `Azure_DNS`, resource group `Azure_DNS_RG`), or via `az network dns record-set a add-record`:

| Type | Record | Value |
|------|--------|-------|
| Host A | `{client_lowercase}-egov.aspgov.com` | Reserved public/external IP |

If a record with this name already exists pointing at a different IP, confirm with the requester before overwriting — don't assume it's stale.

---

### Phase 2: Server Provisioning

#### 2.1 Launch Instance from Template

1. Sign into **PALegacyCzp — 797320052894** via AWS Console
2. Navigate to the correct region
3. Go to **EC2 → Launch instance from template**
4. Select template:
   - us-east-1: `lt-0835492de97e6e968` (czp-naviline-use1)
   - us-west-2: `lt-0f44a807767fb1341` (czp-naviline-usw2)
5. Open **Advanced network configuration**
6. Set **Primary IP** to the reserved IP from Netbox
7. Add client-specific tags:

| Tag Key | Value |
|---------|-------|
| `Name` | `{CLIENT}-{ENV}C2GWB001` |
| `cst_name` | `{CLIENT}-{ENV}C2GWB001` |
| `cst_cost_center` | `{CLIENT}` |
| `cst_tenant` | `{client_lowercase}` |

8. Launch the instance

**Or via CLI:**

```powershell
$client = "AUGU"
$env = "P"  # P=prod, T=test
$ip = "172.30.12.XX"  # from Netbox reservation

aws ec2 run-instances --profile PALegacyCzp --region us-east-1 `
  --launch-template LaunchTemplateId=lt-0835492de97e6e968 `
  --network-interfaces "[{\"DeviceIndex\":0,\"SubnetId\":\"subnet-02d80aaf16530a61a\",\"Groups\":[\"sg-0ac3d45578e28d2c7\"],\"PrivateIpAddress\":\"$ip\"}]" `
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$client-${env}C2GWB001},{Key=cst_name,Value=$client-${env}C2GWB001},{Key=cst_cost_center,Value=$client},{Key=cst_tenant,Value=$($client.ToLower())}]" `
  --output json
```

Note the instance ID from the output.

---

### Phase 3: Initial Configuration (RDP)

#### 3.1 Connect via Fleet Manager or SSM Port Forwarding

```powershell
# RDP via SSM port forwarding
aws ssm start-session --profile PALegacyCzp --region us-east-1 --target <INSTANCE_ID> `
  --document-name AWS-StartPortForwardingSession `
  --parameters "portNumber=3389,localPortNumber=33389"
# RDP to localhost:33389
```

Use the key pair `czp-naviline-ami-build` to decrypt the Administrator password:
- PEM file (east): `$env:USERPROFILE\.ssh\czp-naviline-ami-build-use1.pem`
- PEM file (west): `$env:USERPROFILE\.ssh\czp-naviline-ami-build-usw2.pem`

#### 3.2 Set Computer Name and Reboot

```powershell
Rename-Computer -NewName "{CLIENT}-{ENV}C2GWB001" -Restart
```

#### 3.3 Domain Join

```powershell
# Join aspgov.pri domain
Add-Computer -DomainName "aspgov.pri" -Credential (Get-Credential) -Restart
# Enter ASPGOV domain admin credentials when prompted
```

#### 3.4 Activate Windows

GPO will later override the KMS server to `inf-svrkms001.cloud.lcl:1688` which is
unreachable from the CZP subnet. Activate against AWS KMS now before GPO touches it:

```powershell
slmgr /skms 169.254.169.250
slmgr /ato
```

Verify activation succeeded (should show "License Status: Licensed"):

```powershell
cscript //nologo C:\Windows\System32\slmgr.vbs /dli
```

**Note:** If GPO later overrides the KMS setting and the activation watermark returns,
just re-run the commands above.

#### 3.5 Generate RDP Certificate

New instances don't have a machine certificate for RDP. Generate one so that
hostname-based RDP works without NLA errors:

```powershell
# Trigger auto-enrollment from the domain CA
certutil -pulse

# If auto-enrollment doesn't issue a cert within a few minutes, create a self-signed one:
$hostname = "$env:COMPUTERNAME.aspgov.pri"
$cert = New-SelfSignedCertificate -DnsName $hostname -CertStoreLocation "Cert:\LocalMachine\My" -NotAfter (Get-Date).AddYears(5)

# Bind to RDP
$thumbprint = $cert.Thumbprint
wmic /namespace:\\root\cimv2\TerminalServices PATH Win32_TSGeneralSetting Set SSLCertificateSHA1Hash="$thumbprint"

# Add to Trusted Root
Export-Certificate -Cert $cert -FilePath C:\temp\rdp-cert.cer
Import-Certificate -FilePath C:\temp\rdp-cert.cer -CertStoreLocation Cert:\LocalMachine\Root
Remove-Item C:\temp\rdp-cert.cer

# Restart RDP service
Restart-Service TermService -Force
```

**Note for the operator:** After domain join, you may need to run `klist purge` on
your **workstation** before hostname-based RDP will work. This clears stale Kerberos
tickets for the new computer account. Connecting by IP always works immediately.

---

### Phase 4: Active Directory Configuration

#### 4.1 Move Computer Object in ADUC

Sign into aspgov.pri domain controller → ADUC

Move `{CLIENT}-{ENV}C2GWB001` from `aspgov.pri/Computers/` to:
- `aspgov.pri/C2G/`

(Confirm exact OU path — may vary)

#### 4.2 Add Computer to AD Groups

Add `{CLIENT}-{ENV}C2GWB001` to:

| Group | Purpose |
|-------|---------|
| `WSUS_PROD_2AM_GROUP` | Windows Update via WSUS |
| `Apply_Schannel_TLS1_2_Enabled` | TLS 1.2 hardening via GPO |

#### 4.3 Run gpupdate

After group memberships are set, run on the server:

```powershell
gpupdate /force
```

Then reboot to pick up all GPO changes:

```powershell
Restart-Computer -Force
```

---

### Phase 5: Post-Deploy

#### 5.1 SecureLink Entry

Create SecureLink entry at https://securelink.aspgov.com/rss-servlet/signon.action for `{CLIENT}-{ENV}C2GWB001`, using the following values:

| Field | Value |
|-------|-------|
| Name | `{CLIENT} Prod C2G3 web server` (use `Test` in place of `Prod` for test instances) |
| Gatekeeper Group | `C2G3` |
| Additional Gatekeeper Groups | `Horizon_Users`, `Infrastructure`, `TOC_Users` |
| Assign Services Profile | `Windows Profile` |

**Services:**

| Field | Value |
|-------|-------|
| Host | `{CLIENT}-{ENV}C2GWB001.aspgov.pri` |
| Description | `{CLIENT}-{ENV}C2GWB001` |
| Alias | `{CLIENT}-{ENV}C2GWB001` |

#### 5.2 Update RFC

Update the RFC in Salesforce with:
- Instance ID
- Private IP
- Deployment date
- Status: Complete

See [RFC-37896](https://centralsquare.lightning.force.com/lightning/r/RequestForChange__c/a8caZ000000ZkHhQAK/view) as a worked example to follow for field values and formatting.

---

### Phase 6: F5 BIG-IP WAF Configuration (Manual — Not Automated)

This step is not covered by `/czp-naviline-provision` and must always be done by hand, regardless of which deployment path was used above.

**Sites and appliances:**

| Site | AWS Region | Appliance | URL |
|------|------------|-----------|-----|
| Voorhees | us-east-1 | 1 | `https://10.0.30.33/xui/` |
| Voorhees | us-east-1 | 2 | `https://10.0.30.34/xui/` |
| Vegas | us-west-2 | 1 | `https://10.0.60.33/tmui/login.jsp` |
| Vegas | us-west-2 | 2 | `https://10.0.60.34/tmui/login.jsp` |

Each site has one appliance in **Active** mode and one in **Bypass** mode — check the top-left corner of the screen after logging in to confirm which is which. **Only configure the Active appliance** for the site matching the client's deployment region (Voorhees for us-east-1, Vegas for us-west-2) — do not configure the Bypass appliance.

Create the following 4 objects, in order, all under **Local Traffic**:

**1. Node** (Local Traffic → Nodes)

| Field | Value |
|-------|-------|
| Name | `{CLIENT}-{ENV}C2GWB001_{PRIVATE_IP}` |
| Address | `{PRIVATE_IP}` (the Netbox-reserved private IP from Step 1) |
| Description | `{CLIENT} C2G Web Server` |
| Health Monitors | `https_443` |

**2. Pool** (Local Traffic → Pools)

| Field | Value |
|-------|-------|
| Name | `{CLIENT}-{ENV}C2GWB001_Pool` |
| Description | `{CLIENT} C2G Web Server 001` |
| Health Monitors | `https_443` |

Under **New Members**, select the **Node List** radio button, then:
- **Address:** `{CLIENT}-{ENV}C2GWB001_{PRIVATE_IP}` (`{PRIVATE_IP}`) — the node created in step 1
- **Service Port:** `HTTPS`

**3. Policy** (Local Traffic → Policies)

| Field | Value |
|-------|-------|
| Policy Name | `asm_auto_l7_policy__{CLIENT}-{ENV}C2GWB001_VS` |

Create a rule:

| Field | Value |
|-------|-------|
| Rule Name | `default` |

Under "Do the following when the traffic is matched":
- **Enable** → **asm** → for policy `/Common/2019_C2G_Web` → at `client accepted` time

**4. Virtual Server** (Local Traffic → Virtual Servers)

| Field | Value |
|-------|-------|
| Name | `{CLIENT}-{ENV}C2GWB001_VS` |
| Description | `{CLIENT}'s C2G Virtual Server` |
| Source Address | `0.0.0.0/0` |
| Destination Address/Mask | `{PUBLIC_IP}` (the client's public IP) |
| Service Port | `HTTPS` |
| Protocol Profile (Client) | `sungard_tcp_lan` |
| Protocol Profile (Server) | `sungard_tcp_wan` |
| HTTP Profile (Client) | `C2G_2019` |
| SSL Profile (Client) | `/Common/c2g_prod_aspgov_wildcard` |
| SSL Profile (Server) | `/Common/serverssl_c2g_v1` |
| iRules | `/Common/BanUserAgents` |
| Policies | `/Common/asm_auto_l7_policy__{CLIENT}-{ENV}C2GWB001_VS` (the policy from step 3) |
| Default Pool | `{CLIENT}-{ENV}C2GWB001_Pool` (the pool from step 2) |

---

## Quick Reference — Tags (from Launch Template)

| Tag Key | Value | Notes |
|---------|-------|-------|
| `cst_application` | `web_server` | Baked into template |
| `cst_tenancy` | `single` | Baked into template |
| `cst_backup_policy` | `prod` | Baked into template |
| `DataDog` | `enabled` | Baked into template |
| `CloudWatchAgent` | `enabled` | Baked into template |
| `cst_environment` | `prd` | Baked into template |
| `cst_compliance_domain` | `pci` | Baked into template |
| `cst_product_line` | `pa_citizenengagement` | Baked into template |
| `Name` | `{CLIENT}-{ENV}C2GWB001` | Set at launch |
| `cst_name` | `{CLIENT}-{ENV}C2GWB001` | Set at launch |
| `cst_cost_center` | `{CLIENT}` | Set at launch |
| `cst_tenant` | `{client_lowercase}` | Set at launch |

---

## Quick Reference — Launch Templates

| Region | Template ID | Template Name |
|--------|-------------|---------------|
| us-east-1 | `lt-0835492de97e6e968` | czp-naviline-use1 |
| us-west-2 | `lt-0f44a807767fb1341` | czp-naviline-usw2 |

---

## Quick Reference — Key Pairs

| Region | Key Pair Name | PEM Location |
|--------|---------------|--------------|
| us-east-1 | `czp-naviline-ami-build` | `$env:USERPROFILE\.ssh\czp-naviline-ami-build-use1.pem` |
| us-west-2 | `czp-naviline-ami-build` | `$env:USERPROFILE\.ssh\czp-naviline-ami-build-usw2.pem` |

---

## Quick Reference — AD Groups for Computer Object

| Group | Purpose |
|-------|---------|
| `WSUS_PROD_2AM_GROUP` | WSUS updates via GPO |
| `Apply_Schannel_TLS1_2_Enabled` | TLS 1.2 hardening via GPO |

---

## Quick Reference — F5 BIG-IP Sites

| Site | AWS Region | Appliance URLs |
|------|------------|----------------|
| Voorhees | us-east-1 | `https://10.0.30.33/xui/`, `https://10.0.30.34/xui/` |
| Vegas | us-west-2 | `https://10.0.60.33/tmui/login.jsp`, `https://10.0.60.34/tmui/login.jsp` |

One appliance per site is Active, the other is Bypass — check the top-left corner after login. Only configure the Active appliance for the region matching the client's deployment.

---

## Deployments Log

| Client | Instance ID | Name | Region | Date | Status |
|--------|-------------|------|--------|------|--------|
| | | | | | |
