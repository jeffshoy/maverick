# Foundation Service Restart Tool

Remotely restart Windows services on Foundation OU servers via AWS SSM.
Built for responding to LogicMonitor alerts.

## Usage

**Kiro task (preferred):** run **`AWS: Restart Service`** from the task picker. Leave the account prompt blank to get the GUI OU picker.

**CLI:**
```
cd %USERPROFILE%\repos\cloudops
python scripts\aws\service-restart\restart_services.py
```

Add `--account <NAME>` to skip the picker (e.g. `--account PLUS`).

## Flow

1. GUI popup — searchable dropdown to pick the AWS OU (reads from `~/.aws/config`)
2. SSO login — opens browser if session expired
3. Enter server name (e.g. `REDB-PTRKWB001`)
4. Finds the EC2 instance across us-east-1 and us-west-2
5. Shows SSM connection status
6. Enter service wildcard (e.g. `*Superion*` or `*Trakit*`)
7. Displays matching services with their status
8. Select by number to start/restart
9. Shows updated status
10. Loop — search for more services or exit

## Supported OUs

The GUI dropdown automatically loads **all** profiles from `~/.aws/config` that use `sso_session = foundation`. Currently that includes **80+ accounts**:

- All `PALegacyFinEnt*` accounts (77)
- `PALegacySharedServices`
- `PALegacyCommDev`
- `PALegacyCzp`
- `PALegacyAnalytics`
- `Shared`
- And any future profiles you add

To add more accounts, run the **`Setup: Sync AWS Config`** Kiro task after pulling the latest `aws-configs/cloudops.config` from the repo, or see `aws-configs/README.md` for the manual refresh procedure.
