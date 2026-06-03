# Site Investigation

## When to use

- LogicMonitor alert: site URL unreachable or HTTP error
- User-reported site or application outage on an IIS-hosted server
- Recurring IIS app pool crashes on Trakit/PTRK servers (use **Path B — Recycle Fix**)

Two tools are available. Use **Path A** for an active outage. Use **Path B** when app pools are crashing repeatedly on Trakit servers and you want to apply a persistent configuration fix.

---

## Pre-checks

- [ ] Identify the server name or client code and the account it lives in
- [ ] AWS SSO session is active (run `Setup: AWS SSO Login` if needed)
- [ ] SSM agent is reachable on the target
- [ ] **For Path B (Recycle Fix):** obtain a change ticket before applying config changes — the IIS metabase writes persist across reboots

---

## Path A — Investigate Site (active outage)

### 1. Run the investigation script

Run in Kiro: **`AWS: Investigate Site`**

Or from CLI:
```powershell
python scripts/aws/site-monitor/investigate.py --account <AccountName>
```

### 2. Provide the LM alert block

The script prompts you to paste the full LogicMonitor alert block. Copy it from the LM email or Teams notification — include the `Service URL`, `Service Group`, `Value`, and `Start` fields. Press **Enter twice** when done.

The script auto-extracts the client code and datacenter (Voorhees/Vegas).

If the extraction is wrong, you can override the client code when prompted.

### 3. Select the server

The script finds matching instances. Select the target by number.

The script then queries the server via SSM and displays:
- IIS app pool status (all pools and their states)
- IIS site status (all sites)
- Application and System event log entries from the past 6 hours (Errors and Critical only)

Review this output before taking any action.

### 4. Remediate

The script presents an action menu. Each choice requires confirmation (`yes`/`no`):

| Option | What it does | Blast radius |
|--------|-------------|-------------|
| Start app pool `<name>` | Starts a stopped app pool | Single pool |
| Restart app pool `<name>` | Recycles a running app pool | Single pool |
| Restart IIS (`iisreset`) | Stops and restarts all pools and sites | All IIS on this server |
| Reboot server | Forces a full OS reboot | Server unavailable ~3-5 min |
| Re-investigate | Re-runs the status query | Read-only |
| Exit | Quits the script | — |

> **Reboot severs the SSM session.** The tool will disconnect. Wait 3-5 minutes before re-investigating or checking health in the AWS console.

---

## Path B — Investigate Site (Recycle Fix)

Use this when Trakit (`PTRK`) app pools are crashing repeatedly due to memory pressure or ping timeouts. This applies **persistent IIS metabase configuration** — it survives reboots.

### 1. Run the recycle fix script

Run in Kiro: **`AWS: Investigate Site (Recycle Fix)`**

Or from CLI:
```powershell
python scripts/aws/site-monitor/investigate_recycle_fix.py --account <AccountName>
```

### 2. Enter client codes

Enter comma-separated client codes for the affected clients (e.g. `AURO,DNTN,PIED,REDB`). The script searches for `*<code>*PTRK*` servers — Trakit servers only.

### 3. Review diagnostics

For each server, the script reports:
- App pool recycling config (current periodic restart time, private memory limit, ping timeout)
- W3WP process working set (current memory usage)
- OS memory summary
- Event log: WAS/W3SVC crashes (last 14 days), ping timeout failures (last 7 days), Netlogon errors (last 7 days)
- Superion/Trakit service states

### 4. Apply fixes (confirm with `yes`)

Choose from the fix menu:

| Option | What it changes | Effect |
|--------|----------------|--------|
| Apply ALL | Options 2 + 3 + 4 below | — |
| Recycling only | Sets `recycling.periodicRestart.time = 1740 min` (29h) and `privateMemory = 4,000,000 KB (~4 GB)` on Trakit pools missing recycle config | Takes effect within 29h or at next pool recycle |
| Ping timeout only | Sets `processModel.pingResponseTime = 120s` on pools with recent ping failures | Takes effect immediately for new worker processes |
| Restart stopped services | Starts any stopped Superion/Trakit services | Immediate |
| Exit | Quit without changes | — |

> These are persistent IIS metabase writes. They do not revert on reboot. Document the change ticket number in your ticket before confirming.

---

## Verification

**Path A:**
- Re-run "Re-investigate" from the menu, or re-run the script and check that all pools show `Started` and sites show `Started`
- Check LM — the alert should clear on the next poll cycle (~5 minutes)

**Path B:**
- Re-run the script and confirm the recycling/ping config now shows the new values
- Monitor for ~30 minutes — the ping timeout fix should stop new Event ID 5010 entries

---

## Rollback

**Path A — App pool restart / IIS reset:** non-destructive, no undo needed.

**Path A — Reboot:** recovers automatically. If the server does not come back within 10 minutes:
1. Check instance health in the AWS console (EC2 → Status checks)
2. If hardware failure: stop and start the instance (moves to new hardware)

**Path B — Recycle Fix:** revert the config changes manually via RDP:
```powershell
# Revert periodic restart time (0 = disabled)
Set-ItemProperty -Path "IIS:\AppPools\<PoolName>" `
    -Name "recycling.periodicRestart.time" -Value ([TimeSpan]::Zero)

# Revert private memory limit (0 = no limit)
Set-ItemProperty -Path "IIS:\AppPools\<PoolName>" `
    -Name "recycling.periodicRestart.privateMemory" -Value 0

# Revert ping response time (90s is the IIS default)
Set-ItemProperty -Path "IIS:\AppPools\<PoolName>" `
    -Name "processModel.pingResponseTime" -Value ([TimeSpan]::FromSeconds(90))
```

Replace `<PoolName>` with the affected pool name(s).

---

## Related

- [`inventory/ssm-documents.yml`](../inventory/ssm-documents.yml) — SSM document reference (`AWS-RunPowerShellScript`)
- [`runbooks/aws-sso-setup.md`](aws-sso-setup.md) — if SSO session is expired
- [`scripts/aws/site-monitor/README_recycle_fix.md`](../scripts/aws/site-monitor/README_recycle_fix.md) — technical detail on recycle fix thresholds
