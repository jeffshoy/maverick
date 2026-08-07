# SMTP Relay Architecture & Operations – US\-East\-1

## 1. Architecture

### High‑Level Design

```
┌──────────────────────────┐
│ Datacenter Applications │
│ & AWS Application Hosts │
└─────────────┬────────────┘
              │ SMTP 25 / 587
              ▼
┌──────────────────────────┐
│  NGINX SMTP Relay       │
│  inf-ngxrelay001        │
│  (TCP stream proxy)     │
│  Datacenter             │
└─────────────┬────────────┘
              │ TCP 25 / 587
              ▼
┌──────────────────────────┐
│  Postfix SMTP Relay     │
│  inf-relay001           |
│  AWS USE1               |  
│  Windows Server + WSL2  │
│  Postfix runs in WSL    │
└─────────────┬────────────┘
              │ TCP 587
              ▼
┌──────────────────────────┐
│  Amazon SES              │
│  us-east-1               │
│  External Mail Delivery  │
└──────────────────────────┘
```

### Key Components

| Component | Purpose |
| --- | --- |
| PALegacySharedServices 361362055558 | AWS Account |
| `inf-ngxrelay001` | Datacenter NGINX TCP relay |
| `inf-relay001` | Postfix relay host |
| Windows + WSL2 | Isolates Linux Postfix on Windows |
| Amazon SES | Outbound email delivery |

### NGINX SMTP Relay

**Purpose:**  
Performs TCP 25 / 587 forwarding to inf-relay001.cloud.lcl

```
Hostname:      inf-ngxrelay001.cloud.lcl
Private IP:    172.30.20.97
Role:          NGINX TCP relay (ports 25, 587)
Region:        Datacenter
```

---

### Postfix SMTP Relay (Backend)

**Purpose:**  
Receives SMTP connections from NGINX and relays outbound mail via Amazon SES.

```
Hostname:      inf-relay001.cloud.lcl
Instance ID:   i-034b91ef8516afd72
Private IP:    172.30.249.43
Role:          Postfix SMTP relay (Windows + WSL2)
Region:        us-east-1
```

### Dedicated Amazon SES IPs

SES uses a **dedicated sending IP**, owned by CentralSquare.

| SES Endpoint | Dedicated IPs | Dedicated IP Pool |
| --- | --- | --- |
| [email-smtp.us-east-1.amazonaws.com](http://email-smtp.us-east-1.amazonaws.com) | 24.110.92.194 | [relay\_pools](https://361362055558-ss6yhern.us-east-1.console.aws.amazon.com/ses/home#/dedicated-ips/relay_pools) |

### 2. Access & Management  
  
All credentials can be found in NPM under “infrastructure/AWS SES”

### Access Method

| Host | Access |
| --- | --- |
| NGINX (`inf-ngxrelay001`) | **SSH/Putty **via localadmin account |
| Relay (`inf-relay001`) | **RDP **via svc-wsl-relay account |
| WSL/Postfix | Via `relayadmin` account |

### Service Account

| Item | Value |
| --- | --- |
| Windows service account | `cloud\svc-wsl-relay` |
| WSL distro owner | `cloud\svc-wsl-relay` |
| Scheduled tasks | Run as `cloud\svc-wsl-relay` |

### IAM User

| Item | Value |
| --- | --- |
| IAM User | `ses-relay-service-use1` |
| Purpose | Generate SES SMTP credentials |
| Used by | Postfix SMTP relay |

## 3. WSL & Service Startup

### WSL Auto‑Start

WSL runs **per Windows user**, not system‑wide.  
To ensure reboot safety (Windows Update, host restarts):

**Scheduled Tasks**

- WSL Health Monitor - Checks WSL and postfix status every minute and starts service if stopped. Logs all activity to "C:\\Logs\\wsl-monitor.log" (5MB limit)
- WSL2 Port Forwarding Update – Starts WSL on system startup and updates port forwarding to active WSL IP

## 4. Postfix Relay Configuration

### Configuration Files

| File | Purpose |
| --- | --- |
| `/etc/postfix/main.cf` | Core Postfix config |
| `/etc/postfix/relay_domains` | Allowed sender domains |
| `/etc/postfix/sasl_passwd` | SES SMTP credentials |
| /etc/systemd/system/apt-daily.timer.d/override.conf | Package list refresh |
| /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf | OS & Postfix upgrades |

### Maintenance Window

- Sunday
- 12:00 AM – 12:00 PM (eastern time)

### Update Mechanism

- Ubuntu unattended-upgrades
- Managed via systemd timers inside WSL

### Effective Timer Configuration

- `apt-daily` → Sun 12:00 AM
- `apt-daily-upgrade` → Sun 1:00 AM
- Randomized execution disabled

## 5. NGINX SMTP Relay

NGINX is configured in **TCP stream mode**.

**Ports**

- 25 – standard SMTP
- 587 – SMTP submission (apps → relay)

NGINX performs **no SMTP inspection** and forwards traffic directly to Postfix.

## 6. Operational Notes

- Only **one WSL instance exists** (owned by `svc-wsl-relay`)
- Postfix restarts cleanly across reboots

## 7. Adding a New Client

This section explains **exactly how to onboard a new customer** so their applications can send email via the relay.

### Preferred Method: `/smtp-add-client` Skill

Cloud Ops now has a Claude Code skill that automates Steps 2 and 3 below. Run it from a `cloudops` repo session:

```
/smtp-add-client <clientdomain.com> <east|west>
```

- `<clientdomain.com>` — the client's sending domain.
- `<east|west>` — which AWS region to create the SES identity in (`east` = us-east-1, `west` = us-west-2).

Example:
```
/smtp-add-client cityofsolanabeach.ca.gov west
```

Regardless of which region is chosen, the skill adds the domain to `relay_domains` on **both** Postfix relays — `inf-relay001` (us-east-1, this document) and `inf-relay101` (us-west-2, see the [US-West-2 doc](SMTP%20Relay%20Architecture%20%26%20Operations%20%E2%80%93%20US-West-2.md)) — for failover. It creates the SES verified identity (Easy DKIM), saves the DKIM CNAME records to a CSV in Downloads to send to the client, and inserts the domain alphabetically into the Government section of `relay_domains` on each relay, then reloads Postfix and validates the entry.

Full reference: [`runbooks/smtp-relay-client-onboarding.md`](smtp-relay-client-onboarding.md) — infrastructure detail, troubleshooting table, and why WinRM loopback is used.

The manual steps below remain as reference for when the skill can't be used (e.g. no Claude Code access, SSM/WinRM unavailable on a relay).

---

## Step 1: Obtain Client Information

Before making changes, collect:

| Item | Required |
| --- | --- |
| Sending domain(s) | ✅ Yes |
| Region needed | USE1 / USW2 / Both |

---

## Step 2: Verify Domain in Amazon SES


### Actions

1. Navigate to SES:
2. Select **Verified Identities**:
3. Click **Create Identity**:
4. Enter the following *Identity details*:
    - Identity type: Domain
    - Domain: the name of the customer’s domain.
5. Enter the following *Verifying your domain* details:
    - Advanced DKIM settings → Identity type: Easy DKIM
    - Advanced DKIM settings → DKIM signing key length: RSA\_2048\_BIT
    - Advanced DKIM settings → Publish DNS records to Route53: Disabled
    - Advanced DKIM settings → DKIM signatures: Enabled
6. Click **Create Identity**.
7. On the new domain’s detail page, under **DomainKeys Identified Mail (DKIM)** click **Download .csv record set**. This will download the DKIM records the customer must add to their domain through whatever DNS provider they are using.

    
8. Once the customer has added the necessary records, the *Identity status* will go from *Verification pending *to *Verified*:

Once it is *Verified*, this section is complete.

---

## Step 3: Add Domain to Postfix Relay Authorization

1. RDP to inf-relay001.cloud.lcl
    1. **Use cloud\\svc-wsl-relay**
2. Open Powershell
    1. wsl
    2. sudo -i
    3. sign in using relayadmin password
3. File to Edit
    1. nano /etc/postfix/relay\_domains
4. Add the domain - **KEEP THE LIST ALPHABETIZED**
    1. *newclientdomain.com*     OK
    2. Ctrl + O → Enter → Ctrl + X
5. Apply Changes
    1. sudo postmap /etc/postfix/relay\_domains
    2. sudo systemctl reload postfix
6. Validate Relay Authorization
    1. postmap -q *newclientdomain.com* hash:/etc/postfix/relay\_domains
7. Expected:
    1. OK

# Application Setup

This section is informational only. If it can be configured in a GUI, it is the job of Professional Services, Support, and/or the customer to set it up. This is not the job of Cloud Ops.

The following information is what needs to be entered anywhere in the application is asks for SMTP credentials:

### Datacenter / Legacy Clients

```
SMTP Server: relay.aspgov.com
SMTP Port:   25
Authentication: None
```

### AWS Applications

```
SMTP Server: inf-relay001.cloud.lcl
SMTP Port:   25
Authentication: None
```

## 8. Vendor Documentation

- Amazon SES SMTP:  
<https://docs.aws.amazon.com/ses/latest/dg/send-email-smtp.html> 
- Postfix Relay Configuration:  
<http://www.postfix.org/relayhost.html>
- NGINX Stream Module:  
[https://nginx.org/en/docs/stream/ngx\_stream\_core\_module.html](https://nginx.org/en/docs/stream/ngx_stream_core_module.html)
- Managing Dedicated IP Pools:

[Assigning IP pools in Amazon SES - Amazon Simple Email Service](https://docs.aws.amazon.com/ses/latest/dg/managing-ip-pools.html)
