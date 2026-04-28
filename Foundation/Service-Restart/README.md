# Foundation Service Restart Tool

Remotely restart Windows services on Foundation OU servers via AWS SSM.
Built for responding to LogicMonitor alerts.

## Usage

```
cd C:\Users\sunil.kanakappagari\cloudops\Foundation\Service-Restart
python restart_services.py
```

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

| Profile | Account ID |
|---------|-----------|
| PALegacySharedServices | 361362055558 |
| PALegacyCommDev | 852998999214 |
| PALegacyCzp | 797320052894 |
| PALegacyAnalytics | 179934977755 |

Add more by appending profiles to `~/.aws/config` with `sso_session = foundation`.
