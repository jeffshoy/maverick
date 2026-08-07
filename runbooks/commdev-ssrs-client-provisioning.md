# Comm Dev (TRAKiT) SSRS – New Client Provisioning Runbook

## Overview

This runbook covers the end-to-end process for provisioning a new Comm Dev (TRAKiT) SSRS client's test environment in AWS. The process provisions two servers (a TRAKiT Web Server and an SSRS Remote Desktop server), configures networking/DNS, sets up Active Directory objects, and onboards client users.

## Prerequisites

- Access to AWS SSO: https://d-9067f93f22.awsapps.com/start/#/
- Access to Netbox: https://netbox.aspgov.com/
- Access to Azure DNS (aspgov.com zone)
- Access to Salesforce for RFC creation
- ASPGOV domain admin credentials
- Access to aspgov.pri domain controller (ADUC)
- Access to SecureLink: https://securelink.aspgov.com/rss-servlet/signon.action

## AWS Accounts & Region Selection

| Resource | AWS Account | Account ID |
|----------|-------------|------------|
| Web Server | PALegacyCommDev | 852998999214 |
| RD Server | PALegacySharedServices | 361362055558 |

**Region selection** (applies to both accounts):

| Client Timezone | AWS Region |
|-----------------|------------|
| Eastern / Central | us-east-1 |
| Mountain / Western (Pacific) | us-west-2 |

---

## Phase 1: Pre-Provisioning

### 1.1 Reserve IP Addresses in Netbox

Go to [Netbox](https://netbox.aspgov.com/) → IPAM → Prefixes

Reserve three IP addresses (all must be above .20 in their respective subnets):

| Resource | East (us-east-1) Prefix | West (us-west-2) Prefix |
|----------|------------------------|------------------------|
| Web Server (Internal) | 172.30.17.0/24 | 172.29.17.0/24 |
| RD Server (Internal) | 172.30.41.0/24 | 172.29.41.0/24 |
| RD Server (External) | 192.88.54.0/24 or 74.114.65.0/24 | 74.114.66.0/24, 74.114.67.0/24, or 74.114.69.0/24 |

For each:
1. Find the next available IP above .20
2. Create the reservation record in Netbox

### 1.2 Create DNS Records

**Internal DNS (aspgov.pri):**

| Type | Record | Value |
|------|--------|-------|
| Host A | `<CLIENTCODE>-TTRKWB001.aspgov.pri` | Internal Web Server IP |
| Host A | `<CLIENTCODE>-PTRKRD001.aspgov.pri` | Internal RD Server IP |

**Internal CNAME (inf-svrdns001.cloud.lcl):**

| Alias | Target |
|-------|--------|
| `<CLIENTCODE>-PTRKRD001.aspgov.pri` | `<CLIENTCODE>-TRK-SSRS-RD.aspgov.com` |

**External DNS (Go to [Azure DNS](https://portal.azure.com/)  – aspgov.com zone → Recordsets):**

| Type | Record | Value |
|------|--------|-------|
| Host A | `<CLIENTCODE>-TRK-SSRS-RD.aspgov.com` | External RD Server IP |

### 1.3 Create RFC in Salesforce

Create an RFC in Salesforce. Use **RFC-37311** as a reference template.

Include:
- AWS accounts involved
- Client name, state, client code, and timezone
- Number of new servers (2)
- IPAM reservations and DNS entries

---

## Phase 2: Server Provisioning (AWS)

### 2.1 Launch Web Server

1. Sign into **PALegacyCommDev – 852998999214** via AWS Console
2. Navigate to the correct region (us-east-1 or us-west-2)
3. Go to **EC2 → Launch instance from template**
4. Select template:
   - us-east-1: `lt-0d0da98cd5c1c547c`
   - us-west-2: `lt-0c2b915cc88bfae99`
5. Open **Advanced network configuration**
6. Set **Primary IP** to the reserved internal web server IP
7. Add tags:

| Tag Key | Value |
|---------|-------|
| `cst_cost_center` | `<CLIENTCODE>` |
| `cst_name` | `<CLIENTCODE>-TTRKWB001` |
| `Name` | `<CLIENTCODE>-TTRKWB001` |

8. Launch the instance

### 2.2 Launch RD Server

1. Sign into **PALegacySharedServices – 361362055558** via AWS Console
2. Navigate to the correct region (us-east-1 or us-west-2)
3. Go to **EC2 → Launch instance from template**
4. Select template:
   - us-east-1: `lt-065f10551a730d408`
   - us-west-2: `lt-068c372cd71688e34`
5. Open **Advanced network configuration**
6. Set **Primary IP** to the reserved internal RD server IP
7. Add tags:

| Tag Key | Value |
|---------|-------|
| `cst_cost_center` | `<CLIENTCODE>` |
| `cst_name` | `<CLIENTCODE>-PTRKRD001` |
| `Name` | `<CLIENTCODE>-PTRKRD001` |

8. Launch the instance

---

## Phase 3: Domain Join & Computer Configuration

### 3.1 Domain Join – Web Server

1. RDP into the web server using the appropriate key pair:
   - us-east-1: **ssrs_ttrkwb_aspgov**
   - us-west-2: **ssrs_ttrkwb_lv_aspgov**
2. Change computer name to `<CLIENTCODE>-TTRKWB001`
3. Join domain `aspgov.pri` — authenticate with ASPGOV domain admin account
4. Restart the server

### 3.2 Domain Join – RD Server

1. RDP into the RD server using the appropriate key pair:
   - us-east-1: **ssrs_rd_aspgov**
   - us-west-2: **ssrs_rd_lv_aspgov**
2. Change computer name to `<CLIENTCODE>-PTRKRD001`
3. Join domain `aspgov.pri` — authenticate with ASPGOV domain admin account
4. Restart the server

### 3.3 Move Computer Objects in ADUC

Sign into aspgov.pri and open **Active Directory Users and Computers (ADUC)**.

Navigate to `aspgov.pri/Computers/` and move:

| Computer Object | East Destination | West Destination |
|-----------------|-----------------|-----------------|
| `<CLIENTCODE>-TTRKWB001` | `aspgov.pri/TRAKiT/VNJ` | `aspgov.pri/TRAKiT/LVN` |
| `<CLIENTCODE>-PTRKRD001` | `aspgov.pri/TRAKiT/TRAKiT SSRS RD/VNJ` | `aspgov.pri/TRAKiT/TRAKiT SSRS RD/LVN` |

### 3.4 Apply Group Memberships to Computer Objects

**Web Server (`<CLIENTCODE>-TTRKWB001`):**

- `APPLY-Disable_PCILockdown1_policy`
- `TRAKiT Servers - <Client's TimeZone> Time Zone`
- `TRAKiT Servers`
- `WSUS_TEST_2AM_GROUP`

**RD Server (`<CLIENTCODE>-PTRKRD001`):**

- `APPLY-Disable_PCILockdown1_policy`
- `Terminal Server License Server`
- `TRAKiT Servers - <Client's TimeZone> Time Zone`
- `TRAKiT SSRS RD Servers`
- `WSUS_PROD_2AM_GROUP`

---

## Phase 4: Active Directory – Customer OU & Users

### 4.1 Create Customer OU Structure

In ADUC, create the following OU structure:

```
aspgov.pri/Customer/<CLIENTCODE>        ← Protect from accidental deletion
    ├── GROUPS
    └── USERS
```

### 4.2 Create Security Groups

Inside `aspgov.pri/Customer/<CLIENTCODE>/GROUPS`, create:

| Group Name | Type | Scope |
|------------|------|-------|
| `<CLIENTCODE> TRAKiT SSRS RD Users` | Security | Global |
| `<CLIENTCODE>_VPN` | Security | Global |

### 4.3 Create Client User Accounts

For each requested user:

1. Create user account in `aspgov.pri/Customer/<CLIENTCODE>/USERS`
2. Add user to:
   - `<CLIENTCODE> TRAKiT SSRS RD Users`
   - `<CLIENTCODE>_VPN`
3. Create corresponding user account in the `centroid.cloud.lcl` domain

---

## Phase 5: Managed Service Account (MSA)

### 5.1 Create the MSA

While still on the aspgov.pri domain controller, open PowerShell as admin and run:

```powershell
New-ADServiceAccount <CLIENTCODE>_TTRKMSA `
    -Path "CN=Managed Service Accounts,DC=aspgov,DC=pri" `
    -DNSHostName <CLIENTCODE>_TTRKMSA.aspgov.pri `
    -PrincipalsAllowedToRetrieveManagedPassword "TRAKiT servers"
```

### 5.2 Install MSA on the Web Server

1. RDP into `<CLIENTCODE>-TTRKWB001` using your ASPGOV domain account
2. Open PowerShell as admin and run:

```powershell
Set-ADServiceAccount -Identity <CLIENTCODE>_TTRKMSA `
    -PrincipalsAllowedToRetrieveManagedPassword "<CLIENTCODE>-TTRKWB001$"

Install-ADServiceAccount <CLIENTCODE>_TTRKMSA
```

3. Verify the MSA installation:

```powershell
Test-ADServiceAccount <CLIENTCODE>_TTRKMSA
```

Expected result: `True`

---

## Phase 6: SecureLink & Client Communication

### 6.1 Create SecureLink Entries

Go to [SecureLink](https://securelink.aspgov.com/rss-servlet/signon.action) and create entries for:

- `<CLIENTCODE>-TTRKWB001` (Web Server)
- `<CLIENTCODE>-PTRKRD001` (RD Server)

### 6.2 Email Client Credentials

Send an **encrypted email** to each client user with:

- Their login credentials
- Attachments:
  - `RDP_MFA_CommDev.pdf`
  - `SSRS RD account User Guide.docx`

---

## Quick Reference – Naming Conventions

| Item | Pattern | Example (AVEN) |
|------|---------|----------------|
| Web Server hostname | `<CLIENTCODE>-TTRKWB001` | AVEN-TTRKWB001 |
| RD Server hostname | `<CLIENTCODE>-PTRKRD001` | AVEN-PTRKRD001 |
| RD Server FQDN (external) | `<CLIENTCODE>-TRK-SSRS-RD.aspgov.com` | AVEN-TRK-SSRS-RD.aspgov.com |
| AD RD Users group | `<CLIENTCODE> TRAKiT SSRS RD Users` | AVEN TRAKiT SSRS RD Users |
| AD VPN group | `<CLIENTCODE>_VPN` | AVEN_VPN |
| Managed Service Account | `<CLIENTCODE>_TTRKMSA` | AVEN_TTRKMSA |
| Customer OU | `aspgov.pri/Customer/<CLIENTCODE>` | aspgov.pri/Customer/AVEN |

---

## Quick Reference – EC2 Launch Templates

| Server | Region | Template ID | AWS Account |
|--------|--------|-------------|-------------|
| Web Server | us-east-1 | `lt-0d0da98cd5c1c547c` | PALegacyCommDev (852998999214) |
| Web Server | us-west-2 | `lt-0c2b915cc88bfae99` | PALegacyCommDev (852998999214) |
| RD Server | us-east-1 | `lt-065f10551a730d408` | PALegacySharedServices (361362055558) |
| RD Server | us-west-2 | `lt-068c372cd71688e34` | PALegacySharedServices (361362055558) |

---

## Quick Reference – Key Pairs

| Server | Region | Key Pair |
|--------|--------|----------|
| Web Server | us-east-1 | `ssrs_ttrkwb_aspgov` |
| Web Server | us-west-2 | `ssrs_ttrkwb_lv_aspgov` |
| RD Server | us-east-1 | `ssrs_rd_aspgov` |
| RD Server | us-west-2 | `ssrs_rd_lv_aspgov` |

---

## Notes

- Always verify IP availability in Netbox before provisioning — do not reuse IPs from decommissioned hosts without confirming they are released.
- RFC reference: RFC-37311 in Salesforce.
