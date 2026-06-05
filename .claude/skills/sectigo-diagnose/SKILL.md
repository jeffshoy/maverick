---
name: sectigo-diagnose
description: Diagnose why a server is inactive on a Sectigo SCM Network Agent. Use when a server is registered but not communicating — walks through the ranked causes (local admin group, network connectivity, credentials, agent service). Diagnostic only — makes no changes. (e.g. "why is BELT-PXSF001 inactive?", "/sectigo-diagnose CCWD-PXSF001", "sectigo isn't scanning this server").
---

# /sectigo-diagnose — Troubleshoot an inactive Sectigo server

**Diagnostic only — no changes are made.**

The Sectigo API returns only `active: true/false` with no reason field. All diagnosis is done by asking the user to run tests from the shared agent host (`INF-PLIWK101.cloud.lcl`) or on the target server itself.

## Step 1 — Confirm the server is actually inactive

Run `/sectigo-find <server>` first (or re-use results if already known).

- If **active: true** → tell the user the server is healthy and stop.
- If **not registered** → tell the user to run `/sectigo-add` instead and stop.
- If **active: false** → proceed to Step 2.

## Step 2 — Walk the decision tree in order

Work through these causes from most common to least, stopping as soon as the user confirms a match:

### Cause 1 — Missing local Administrators group membership (most common)

The Sectigo agent on `INF-PLIWK101` connects to target servers using `CLOUD\sectigo_svc`. That account must be a member of the local **Administrators** group on the target.

Ask the user: *"Has the Sectigo service account (`CLOUD\sectigo_svc`) been added to the local Administrators group on `<SERVER>`?"*

If no → this is likely the fix. The same issue resolved `BRENT-PXSF002` earlier. Instruct them to add it and wait for the next agent scan cycle.

### Cause 2 — Network connectivity (agent cannot reach the server)

The Sectigo agent on `INF-PLIWK101` connects via WinRM (port 5985 by default for REMOTE_LEGACY_NATIVE_API / IIS).

Suggest running this **from INF-PLIWK101**:
```powershell
Test-NetConnection -ComputerName <SERVER> -Port 5985
```

- `TcpTestSucceeded: False` → firewall or routing issue between INF-PLIWK101 and the target. Escalate to networking.
- `TcpTestSucceeded: True` → port is open; move to Cause 3.

### Cause 3 — Credential or WinRM configuration issue

If the port is reachable but the scan still fails, the agent is connecting but being rejected. Common sub-causes:
- `CLOUD\sectigo_svc` password changed but not updated in Sectigo SCM.
- WinRM not configured or HTTPS required (`winrm quickconfig` not run on target).
- The target requires Kerberos but the agent is presenting NTLM.

Suggest checking the Sectigo agent logs on `INF-PLIWK101` (typically under `C:\Program Files\Sectigo\` or the Sectigo SCM Agent install directory) for the specific error on the last scan attempt for this server.

### Cause 4 — Agent service issue on INF-PLIWK101

Only likely if **multiple servers across both agents went inactive at the same time**.

Suggest checking on `INF-PLIWK101`:
```powershell
Get-Service | Where-Object { $_.DisplayName -like '*Sectigo*' }
```

If stopped → restart the service and monitor.

## Reporting

After each cause, ask the user what they found before moving to the next. Don't dump all four causes at once — step through them interactively.

End with: *"The Sectigo API doesn't expose a reason for inactive status. Once you've applied the fix, the server should flip to active on the next agent scan cycle (typically within a few minutes)."*
