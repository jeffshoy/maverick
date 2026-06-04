# Foundation Server Reboot Tool

Find EC2 instances by client/server code, view health status checks, reboot, and monitor until online.

## Usage

**Kiro task (preferred):** run **`AWS: Reboot Server`** from the task picker. Leave the account prompt blank to get the GUI OU picker.

**CLI:**
```
cd %USERPROFILE%\repos\cloudops
python scripts\aws\server-reboot\reboot_server.py
```

Add `--account <NAME>` to skip the picker (e.g. `--account PLUS`).

## Flow

1. GUI popup — searchable dropdown to pick the AWS OU (all 80+ foundation profiles)
2. SSO login — opens browser if session expired
3. Enter client code (e.g. `REDB`) or full server name (e.g. `REDB-PTRKWB001`)
4. Finds matching EC2 instances across us-east-1 and us-west-2
5. Displays: server name, instance ID, state, private IP, health checks (2/2 ok/ok or failing)
6. Select server(s) by number (comma-separated: `1,2`)
7. Confirm reboot (Y/N)
8. Reboots and continuously pings until server is back online
9. Waits for all health checks to pass
10. Shows final status

## Health Check Display

- `2/2 (ok/ok)` — both system and instance checks passing
- `1/2 (ok/impaired)` — system OK but instance check failing
- `0/2 (impaired/impaired)` — both failing
