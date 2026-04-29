# Site Monitor Investigation Tool

Investigates LogicMonitor site monitor alerts by checking IIS status and event logs on the target server via AWS SSM.

## Usage

```
pip install -r requirements.txt
python investigate.py
```

## Flow

1. Select AWS OU (GUI picker)
2. Paste the LM alert block — client code is auto-detected from Service URL/Group
3. Confirm client code or enter a different one
4. Search and select the EC2 instance
5. Runs investigation via SSM:
   - IIS app pool status (started/stopped)
   - IIS site status
   - Event logs (Application, System) — last 6 hours, errors/warnings/critical
6. Displays findings with critical issues highlighted in red
7. Offers remediation options:
   - Start/restart specific stopped app pools
   - Full IIS reset (iisreset)
   - Server reboot

## Requirements

- AWS SSO configured with `foundation` session
- SSM agent running on target instance
- IIS installed on target server
- Python 3.8+
