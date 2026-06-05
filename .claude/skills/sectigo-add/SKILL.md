---
name: sectigo-add
description: Register one or more IIS servers with the Sectigo SCM Network Agent. Discovers the correct agent via AWS region lookup, builds the registration JSON, dry-runs, then adds with confirmation. Use when servers need to be added to Sectigo for certificate management (e.g. "/sectigo-add SDSP-PCOGWB001.aspgov.pri", "add these servers to sectigo", "register MERI-PTRKWB001 in sectigo"). All servers are registered as IIS / REMOTE_LEGACY_NATIVE_API / CLOUD\sectigo_svc.
---

# /sectigo-add — Register IIS servers with a Sectigo Network Agent

## Agent map

| AWS Region | Sectigo Agent |
|---|---|
| us-east-1 | 18227 |
| ca-central-1 | 18227 |
| us-west-2 | 18247 |

## Step 1 — Prerequisites

**Check `$env:SECTIGO_SVC_PASSWORD`** — this is the plaintext password for `CLOUD\sectigo_svc`, needed in the registration JSON. If not set, stop and instruct:
```powershell
$env:SECTIGO_SVC_PASSWORD = 'password-from-password-manager'
```
Never suggest storing it in a file or script. Unset after the session with `Remove-Item Env:SECTIGO_SVC_PASSWORD`.

Also verify `SECTIGO_LOGIN`, `SECTIGO_PASSWORD`, and `SECTIGO_CUSTOMER_URI` are set (required by `add_servers_to_agent.py`).

## Step 2 — Gather server → AWS account mapping

For each server provided, you need the AWS profile that owns it. Ask the user if not provided:
*"Which AWS profile owns `<SERVER>`?"* (e.g. `PALegacyAnalytics`, `PALegacyFinEntCCWD`, `PALegacyPlus`)

Accept a list of `server=profile` pairs up front to avoid asking one at a time.

## Step 3 — Discover region via AWS (use mcp__aws__call_aws)

For each server, query EC2 across `us-east-1`, `us-west-2`, and `ca-central-1` in parallel using the AWS MCP tool. Match on the Name tag with a wildcard — try both the original case and lowercase (Name tags are sometimes all-lowercase in EC2 even when the FQDN is mixed case):

```
aws ec2 describe-instances --profile <PROFILE> --region <REGION>
  --filters "Name=tag:Name,Values=*<HOSTNAME>*" "Name=instance-state-name,Values=running"
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,InstanceId,PrivateIpAddress,Placement.AvailabilityZone]"
  --output text
```

Batch all three regions per server in a single `call_aws` call with a list of commands.

If a server is not found running in any region: stop and report it — do not proceed for that server until the user clarifies. (Instance may be stopped, in a different account, or have a non-standard Name tag.)

Map each found region to the agent ID using the table above.

## Step 4 — Show mapping table and confirm

Before writing any files, display the full planned registration:

| Server (FQDN) | Private IP | Region | Agent |
|---|---|---|---|
| SDSP-PCOGWB001.aspgov.pri | 172.30.38.92 | us-east-1 | 18227 |
| ... | | | |

**Wait for explicit confirmation from the user** before proceeding. This is an irreversible action (servers can be removed but the change is immediate and visible in Sectigo).

## Step 5 — Build JSON files

Write one JSON file per agent to `scripts/sectigo/MassServerAdd/add_<agentid>_<YYYYMMDD>.json`.

Each server entry must use this exact shape:
```json
{
  "name": "<FQDN>",
  "vendor": "IIS",
  "connectionType": "REMOTE_LEGACY_NATIVE_API",
  "ip": "<FQDN>",
  "username": "CLOUD\\sectigo_svc",
  "password": "<value of SECTIGO_SVC_PASSWORD env var>"
}
```

Notes:
- `ip` = the FQDN (not the private IP) — the agent resolves via DNS, same as `build_server_list.py`.
- No `port` field — `REMOTE_LEGACY_NATIVE_API` with `IIS` is the only combination that omits port per `add_servers_to_agent.py` validation.
- Double-backslash in the username is required for valid JSON (`CLOUD\\sectigo_svc`).

Use a Python one-liner to write the file (reads the env var at write time, avoids shell escaping issues):
```
python -c "import json,os; servers=[...]; open('add_18227_YYYYMMDD.json','w').write(json.dumps(servers,indent=2))"
```

## Step 6 — Dry-run

Run dry-run for each file:
```
python add_servers_to_agent.py --agent-id <id> add_<id>_<date>.json --dry-run
```

Show the output. If anything looks wrong (wrong FQDN, wrong agent, wrong username), stop and fix before proceeding.

## Step 7 — Live add

```
python add_servers_to_agent.py --agent-id <id> add_<id>_<date>.json
```

Capture the `id=` returned for each server in the `[OK]` lines.

## Step 8 — Clean up

Delete the JSON files immediately — they contain plaintext credentials:
```
Remove-Item scripts/sectigo/MassServerAdd/add_*.json
```

## Step 9 — Report

Print a final results table:

| Server | Agent | Sectigo ID | Result |
|---|---|---|---|
| SDSP-PCOGWB001.aspgov.pri | 18227 | 232670 | registered |

Remind the user: *"Servers will show as inactive until the Sectigo agent on `INF-PLIWK101` completes its first successful scan. If they remain inactive after a few minutes, run `/sectigo-diagnose <server>`."*
