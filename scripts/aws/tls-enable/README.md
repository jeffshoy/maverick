# TLS 1.2 Enablement Tool

Enables TLS 1.2 (SChannel server/client) and .NET strong crypto on Windows EC2 instances via AWS SSM,
then schedules a one-time reboot for **5:00 AM server-local time** so the change takes effect outside
business hours. Primary targets are the `PROD-PA-Pro` and `Pa-pro-staging` accounts, but any account
in `accounts.json` is accepted.

Registry settings only take effect after a reboot — this tool does **not** reboot immediately. It
writes the values, then registers a self-deleting Scheduled Task that fires at the next 5:00 AM local
to the instance.

**Out of scope:** disabling TLS 1.0/1.1 or legacy ciphers. This tool only enables TLS 1.2 / strong
crypto; it never disables anything.

---

## Prerequisites

- **Python 3.8+** with `boto3` (`pip install -r requirements.txt`)
- **AWS CLI v2** installed
- **SSM Agent** running on target EC2 instances, `AmazonSSMManagedInstanceCore` policy attached
- Target instances must be **Windows** — the tool refuses non-Windows platforms

---

## Usage

**Kiro task (preferred):** run **`AWS: Enable TLS 1.2`** from the task picker.

**CLI:**
```
cd %USERPROFILE%\repos\cloudops
python scripts\aws\tls-enable\tls_enable.py --account <NAME> [--instance ID ...] [--name NAME ...] [--region REGION] MODE
```

Targeting is always **explicit** — there is no "all instances" mode:
- `--instance i-0123456789abcdef0` (repeatable)
- `--name SERVERNAME` (repeatable) — exact, case-insensitive match on the EC2 `Name` tag

### Modes

| Mode | Effect |
|---|---|
| `--check` (default) | Read-only. Reports current registry state, timezone, pending task. No changes. |
| `--apply --dry-run` | Runs the check only, reports what `--apply` would do. No changes. |
| `--apply` | Applies registry values if needed, schedules the 5am-local reboot. **Idempotent** — if already fully compliant, makes no changes and schedules no reboot. |
| `--cancel-reboot` | Unregisters the pending `CloudOps-TLS12-Reboot` task only. Does not touch registry values. |

`--yes` skips the interactive confirmation prompt (for scripted/unattended use).

### Examples

```
# Check compliance on a staging server
python scripts\aws\tls-enable\tls_enable.py --account pac-stg --name PACSTG-PWEBWB001 --check

# Preview what apply would do
python scripts\aws\tls-enable\tls_enable.py --account pac-stg --name PACSTG-PWEBWB001 --apply --dry-run

# Apply and schedule the 5am-local reboot
python scripts\aws\tls-enable\tls_enable.py --account pac-stg --name PACSTG-PWEBWB001 --apply

# Apply across a few named prod servers, unattended
python scripts\aws\tls-enable\tls_enable.py --account pac-prd --name PACPRD-PWEBWB001 --name PACPRD-PWEBWB002 --apply --yes

# Cancel a scheduled reboot (e.g. maintenance window changed)
python scripts\aws\tls-enable\tls_enable.py --account pac-stg --name PACSTG-PWEBWB001 --cancel-reboot
```

---

## Flow

1. Resolve account name → profile, verify/refresh SSO session.
2. Resolve each `--instance`/`--name` target to an instance ID + region (multi-region search:
   us-east-1, us-west-2, ca-central-1 unless `--region` narrows it).
3. Pre-flight: confirm each target is SSM-online **and** Windows. Refuses non-Windows or offline
   instances outright.
4. Print the target table and (for `--apply` without `--dry-run`, or `--cancel-reboot`) require a
   typed `yes` confirmation unless `--yes` is passed.
5. Run the appropriate PowerShell payload via SSM `AWS-RunPowerShellScript` per instance, parse
   `KEY|value` output.
6. Print a per-host result, write a run summary to `%TEMP%\tls-enable-<timestamp>.log`.
7. Exit non-zero if any target failed.

## What gets changed on each instance

Six registry values (only written if not already correct):

- `HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server\Enabled = 1`
- `...\TLS 1.2\Server\DisabledByDefault = 0`
- `...\TLS 1.2\Client\Enabled = 1`
- `...\TLS 1.2\Client\DisabledByDefault = 0`
- `HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319\SchUseStrongCrypto = 1`
- `HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319\SchUseStrongCrypto = 1`

Plus, only if a change was needed:

- A Scheduled Task `CloudOps-TLS12-Reboot` (one-time trigger, next 5:00 AM local, at least 10 minutes
  out — rolls to tomorrow if today's 5am has passed or is too close). Runs as `SYSTEM`.
- A helper script at `C:\ProgramData\CloudOps\Invoke-Tls12Reboot.ps1` that the task invokes — it issues
  `shutdown /r /t 300` (5-minute warning) and then unregisters its own task. Logs to
  `C:\ProgramData\CloudOps\tls12-reboot.log`.

## Blast radius

- **Scope:** only the instances explicitly named via `--instance`/`--name` on a given invocation.
  No fleet-wide discovery.
- **Immediate changes:** registry values (6 keys) and one Scheduled Task + helper script. No reboot
  happens at run time.
- **Deferred change:** a reboot at the instance's next local 5:00 AM. Verify the scheduled time with
  `--check` (`TASK_NEXTRUN`) before walking away, especially for instances in unfamiliar timezones.
- **Rollback:** `--cancel-reboot` removes the pending reboot. The registry values themselves are not
  rolled back by this tool (enabling TLS 1.2 is not expected to need reversal).

## Files

| File | Purpose |
|------|---------|
| `tls_enable.py` | Main CLI tool — account resolve, targeting, SSM orchestration, reporting |
| `Check-Tls12.ps1` | Read-only SSM payload — reports registry state, timezone, pending task |
| `Enable-Tls12.ps1` | SSM payload — applies registry values, schedules the 5am-local reboot |
| `requirements.txt` | Python dependencies |
