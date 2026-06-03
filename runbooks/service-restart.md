# Service Restart

## When to use

- LogicMonitor alert: service down on a client server
- User-reported app outage where a Windows service (Citrix, Trakit, Superion, etc.) is the suspected cause
- Post-patching service verification after a server reboot

---

## Pre-checks

- [ ] Identify the server name or client code and which account it lives in
- [ ] Confirm the service is actually stopped — false alerts fire during planned reboots; check if a maintenance window is active
- [ ] AWS SSO session is active (run `Setup: AWS SSO Login (foundation)` or `legacy` if needed)
- [ ] SSM agent is reachable on the target — the script checks `PingStatus == Online` automatically

---

## Procedure

### 1. Run the service restart script

Run in Kiro: **`AWS: Restart Service`**

Or from CLI:
```powershell
python scripts/aws/service-restart/restart_services.py --account <AccountName>
```

Leave `--account` blank (or the field empty in Kiro) to use the interactive account picker.

### 2. Find the server

The script prompts for a server name or client code:
- Client code: `REDB` — finds all servers matching `*REDB*` across `us-east-1`, `us-west-2`, `ca-central-1`
- Full server name: `REDB-PTRKWB001` — finds that specific server

Select the target server by number.

### 3. Search for the service

Enter a service search pattern. The script wraps it with wildcards automatically:
- `Citrix` → searches for `*Citrix*`
- `Trakit` → searches for `*Trakit*`
- `Superion` → searches for `*Superion*`

The script queries the server via SSM and lists matching services with their current state.

### 4. Select and restart

Enter the number(s) of the service(s) to act on (comma-separated for multiple).

The script:
- If the service is `Running`: calls `Restart-Service`
- If the service is `Stopped`: calls `Start-Service`

After the action, it re-queries and reports the new service state.

### 5. Continue or exit

After each restart, the script offers:
- **Continue** — search for another service on the same server
- **Different OU** — search for a different server
- **Cancel** — exit

---

## Verification

The script reports the service state after each action. Additionally:

- Ask the end user to confirm the app is responding
- Check LM — the service alert should clear on the next poll cycle (~5 minutes)
- If the service starts but immediately stops again, the issue is likely an application error, not an SSM/restart failure — RDP to the server and check the Windows Event Log

---

## Rollback

Service restarts are non-destructive and fully reversible. If the restart made things worse:

1. RDP to the server (`AWS: RDP to Instance`)
2. Stop the affected service: `Stop-Service -Name "<ServiceName>" -Force`
3. Investigate the application logs before restarting again

---

## Related

- [`inventory/ssm-documents.yml`](../inventory/ssm-documents.yml) — SSM document reference (`AWS-RunPowerShellScript`)
- [`runbooks/aws-sso-setup.md`](aws-sso-setup.md) — if SSO session is expired
- [`scripts/aws/service-restart/README.md`](../scripts/aws/service-restart/README.md) — technical detail on the SSM payloads
