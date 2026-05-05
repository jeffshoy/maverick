# IIS Recycle Fix & Diagnostics Tool

## Purpose

`investigate_recycle_fix.py` diagnoses and fixes recurring IIS failures on PALegacy Community Development PTRK web servers caused by **app pool memory leaks**, **missing recycling configuration**, and **low ping response timeouts**.

## Problem Statement

Multiple clients (AURO, DNTN, PIED, REDB, etc.) experience frequent LogicMonitor alerts where their TRAKiT/eTRAKiT sites go down. The pattern:

1. App pools (TRAKIT, etrakit, etrakit_admin, itrakit) have **no periodic recycling** configured (RecycleMin=0, PrivMemKB=0)
2. w3wp worker processes grow unbounded (3-5+ GB memory)
3. Memory pressure causes **app pool ping failures** (Event ID 5010) — sometimes every 45-60 minutes
4. The default **ping response timeout (90 sec)** is too low — the app hangs during heavy DB queries and IIS kills the worker process prematurely
5. Eventually the **Windows Process Activation Service (WAS)** crashes (Event ID 7034), taking IIS down entirely
6. Domain controller authentication failures (NETLOGON errors) compound the issue when MSA accounts can't renew Kerberos tickets under memory pressure
7. LogicMonitor fires a critical alert; IIS restart temporarily resolves it until memory bloats again

### Where This Was Discovered

This issue was identified on **2026-05-05** during investigation of a LogicMonitor critical alert for AURO Community Development (`https://auro-trk.aspgov.com/admin/login.aspx`). The same root cause was confirmed across DNTN, PIED, and REDB clients in the **PALegacyCommDev** AWS OU (Account: 852998999214).

**Key evidence found via SSM event log analysis:**
- AURO-PTRKWB101: WAS/W3SVC terminated unexpectedly, w3wp at 3+ GB, no recycling
- DNTN-PTRKWB001: etrakit_admin ping failures every 45-60 min for 7+ days straight, w3wp at 5.26 GB, ping timeout too low
- PIED-PTRKWB001: etrakit_admin ping failures every 2-3 hours, w3wp at 2.24 GB
- REDB-PTRKWB001: Akka cluster heartbeat delays causing Superion services to stop

Servers that already had recycling configured (e.g., REDB's eTRAKiT at 1740 min, AURO-PTRKWB102) did **not** experience WAS crashes.

## What The Fixes Do

The tool applies three safe remediations:

### 1. App Pool Recycling (Primary Fix)
- Sets **periodic restart = 1740 minutes (29 hours)** — same as already-working pools in the environment
- Sets **private memory limit = 4,000,000 KB (4 GB)** — prevents runaway memory growth

### 2. Ping Response Timeout Fix
- Increases **ping response time from 90 sec → 120 sec**
- Automatically recommended for pools with **5+ ping failures in 7 days** and current timeout under 120 sec
- Gives the application more time to respond during heavy DB operations before IIS kills the worker process

### 3. Service Restart (For REDB-type issues)
- Restarts stopped `Superion.Trakit.Service` and `Superion.Trakit.Legacy.Service`
- These stop when Akka cluster heartbeats are delayed due to thread starvation from memory pressure

## Safety — Why These Fixes Won't Cause Application Failures

All three fixes are safe and will **NOT** cause application downtime or failures:

| Fix | Why It's Safe |
|-----|---------------|
| **Recycling** | IIS uses **overlapped recycling** by default — it starts the new worker process first, then drains the old one. Requests are never dropped. Zero downtime. |
| **Ping timeout (90s → 120s)** | Only gives the app **more time** to respond. Doesn't change any application behavior. Worst case: a truly hung process takes 30 sec longer before IIS recycles it (better than killing it prematurely and triggering an alert). |
| **Service restart** | These services are designed to be started/stopped. They already have Windows recovery actions configured (auto-restart on failure). We're just doing what Windows would do automatically. |

**None of these fixes touch:**
- Application code
- Database connections or connection strings
- Web.config files
- Network/firewall rules
- DNS or domain controller settings

**The only scenario where you'd see a brief blip:** If the 4GB memory limit triggers a recycle while a user is mid-request — but IIS handles this gracefully via overlapped recycling (starts new process before draining old one).

## Usage

```
cd Foundation\Site-Monitor
python investigate_recycle_fix.py
```

### Flow
1. Opens GUI to select AWS OU (defaults to foundation SSO session profiles)
2. Prompts for client code(s) — comma-separated (e.g., `AURO,DNTN,PIED,REDB`)
3. Finds all `*PTRK*` servers for each client in us-east-1 and us-west-2
4. Runs diagnostics via SSM on each server:
   - App pool recycling configuration and ping response timeout
   - w3wp memory usage
   - App pool ping failures (Event 5010, last 7 days)
   - WAS/W3SVC crashes (Event 7034/7031, last 14 days)
   - NETLOGON/DC authentication errors (last 7 days)
   - Superion/TRAKiT service status
5. Displays color-coded findings with highlighted issues
6. Offers fix options:
   - `[1]` Apply ALL fixes (recycling + ping timeout + service restarts)
   - `[2]` Apply recycling fix only
   - `[3]` Apply ping timeout fix only
   - `[4]` Restart stopped services only
   - `[5]` Exit without changes
7. Confirms before applying, shows before/after values

## Requirements

```
pip install boto3 colorama
```

- AWS CLI configured with `foundation` SSO session
- SSM Agent online on target servers
- Sufficient IAM permissions (cst-comm-cloudadmin role)

## Target Environment

- **AWS OU:** PALegacyCommDev (852998999214)
- **Servers:** `*-PTRKWB*` (Production TRAKiT Web servers)
- **Regions:** us-east-1, us-west-2
- **App Pools:** TRAKIT, etrakit, etrakit_admin, itrakit
- **Services:** Superion.Trakit.Service, Superion.Trakit.Legacy.Service

## Related Tools

- `investigate.py` — General site monitor investigation (IIS status, event logs, iisreset, reboot)
- This tool is specifically for the **recycling/memory leak/ping timeout** root cause pattern
