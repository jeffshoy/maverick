# RDS License Grace Period Reset

## When to use

- LogicMonitor alert: "RDS grace period expiring" or "RDS license expired"
- Users report they can no longer connect via RDP to a specific client server with a licensing warning
- Proactive reset before a scheduled grace period expiry (visible in the LM dashboard)

The RDS 120-day grace period counter resets automatically after this procedure. Plan for a ~5-minute server reboot window.

---

## Pre-checks

- [ ] Identify the server name (e.g. `ARCT-PTRKRD001`) and which account it lives in
- [ ] Confirm no users are actively logged in, **or** get explicit approval to kick active sessions — the reset forces a reboot
- [ ] AWS SSO session is active (run `Setup: AWS SSO Login (foundation)` if needed)
- [ ] SSM agent is reachable on the target instance (the script checks this automatically)

---

## Procedure

### 1. Run the reset script

Run in Kiro: **`AWS: Reset RDS License Grace Period`**

Or from CLI:
```powershell
python scripts/aws/rds-license-reset/rds_license_reset.py --account <AccountName>
```

Leave `--account` blank (in Kiro: leave the account field empty) to use the interactive account picker.

### 2. Search for the server

The script prompts for a client code or server name:
- Client code: `ARCT` — finds all servers matching that prefix
- Full server name: `ARCT-PTRKRD001` — finds that specific server

### 3. Review and confirm

The script displays matching instances with health check status. Select the target server by number.

Confirm when prompted. The script will:
1. Send the reset SSM command — deletes the RDS grace period registry key and triggers a reboot
2. Wait for the instance to come back online (pings the private IP)
3. Wait for system + instance health checks to pass (3/3)
4. Report the new grace period day count (should be ~120 days)

Total time: ~3-5 minutes depending on reboot speed.

### 4. Log the reboot

Note the reboot time in your change ticket for the audit trail.

---

## Verification

After the script reports health checks passed:

1. RDP to the server (use `AWS: RDP to Instance` in Kiro)
2. Confirm no RDS licensing warning dialog appears at login
3. Optionally: check the LM dashboard — the grace period metric should have reset

---

## Rollback

Not applicable — the grace period reset is non-destructive and safe to re-run.

The only side effect is the reboot. If the server fails to come back:
1. Check the instance health in the AWS console (EC2 → Instances → Status checks)
2. If hardware failure: stop and start the instance (moves to new hardware)
3. If SSM command stuck: force-stop from EC2 console

---

## Related

- [`scripts/aws/rds-license-reset/README.md`](../scripts/aws/rds-license-reset/README.md) — technical detail on the SSM document and registry key
- [`inventory/ssm-documents.yml`](../inventory/ssm-documents.yml) — SSM document reference
- [`runbooks/aws-sso-setup.md`](aws-sso-setup.md) — if SSO session is expired
