---
name: sectigo-find
description: Find a server on a Sectigo SCM Network Agent and report its status. Use when the user wants to know if a server is registered in Sectigo, which agent it's on, its Sectigo ID, and whether it's active or inactive (e.g. "find BELT-PXSF001 in sectigo", "/sectigo-find CCWD-PXSF001", "is server X registered?").
---

# /sectigo-find — Locate a server on a Sectigo Network Agent

Parse the server name from the user's input, then locate it across both agents.

## Setup check

Before any API calls, verify that `SECTIGO_LOGIN`, `SECTIGO_PASSWORD`, and `SECTIGO_CUSTOMER_URI` are set in the environment. If any are missing, stop and tell the user:
```
Set-Item Env:SECTIGO_LOGIN        'your_scm_username'
Set-Item Env:SECTIGO_PASSWORD     'your_scm_password'
Set-Item Env:SECTIGO_CUSTOMER_URI 'centralsquare'
```

## Lookup steps

Working directory for all commands: `scripts/sectigo/MassServerAdd/`

1. **Cache check first** — grep the local CSV files for a quick answer:
   ```
   grep -ri "<SERVER>" scripts/sectigo/MassServerAdd/servers_*.csv
   ```
   If found, read the agent ID from the filename (`servers_18227_*` vs `servers_18247_*`) and the `active` field from the row. Skip to Reporting.

2. **Live query agent 18227 (us-east-1)**:
   ```
   python list_servers.py --search <SERVER> --agent-id 18227
   ```

3. **If 0 matches on 18227, fall back to agent 18247 (us-west-2)**:
   ```
   python list_servers.py --search <SERVER> --agent-id 18247
   ```

## Reporting

Output a single summary:

| Field | Value |
|---|---|
| Server | `<full name from Sectigo>` |
| Agent | `18227 (us-east-1)` or `18247 (us-west-2)` |
| Sectigo ID | `<id>` |
| Active | `true` or `false` |

If not found on either agent: say the server is **not registered** and suggest `/sectigo-add` to register it.

If multiple partial matches are returned, list them all — do not pick one silently.
