---
name: sectigo-remove
description: Remove servers from a Sectigo SCM Network Agent by name search. Previews matches, confirms scope, dry-runs, then deletes with the script's built-in confirmation prompt. Use when decommissioning servers or cleaning up stale/duplicate registrations (e.g. "/sectigo-remove SMYD-PCOGWB001 --inactive", "remove old servers from sectigo", "clean up inactive servers matching 'smia'").
---

# /sectigo-remove — Remove servers from a Sectigo Network Agent

**Destructive — server removal in Sectigo is immediate. Always dry-run first.**

## Setup check

Verify `SECTIGO_LOGIN`, `SECTIGO_PASSWORD`, and `SECTIGO_CUSTOMER_URI` are set. If missing, stop and show the `Set-Item Env:` commands from `/sectigo-find`.

## Step 1 — Find matching servers

Run against agent 18227 first (if the user doesn't specify):
```
python list_servers.py --search <TERM> [--inactive] --agent-id 18227
```

If 0 matches, fall back to 18247:
```
python list_servers.py --search <TERM> [--inactive] --agent-id 18247
```

Working directory: `scripts/sectigo/MassServerAdd/`

Show the full match list from the script output (ID, active status, name). If matches appear on both agents, show both sets and ask the user which agent to target — do not act on both simultaneously.

## Step 2 — Confirm scope

**Wait for explicit confirmation** before proceeding. State exactly:
- The agent ID
- The number of servers that will be deleted
- The search term and `--inactive` flag (if used)

Example: *"This will remove 3 servers matching 'smyd' on agent 18227. Confirm?"*

## Step 3 — Dry-run

```
python remove_servers_from_agent.py --agent-id <id> --search <TERM> [--inactive] --dry-run
```

Show the full output. If the dry-run list differs from what was shown in Step 1, stop and reconcile before proceeding.

## Step 4 — Live remove

```
python remove_servers_from_agent.py --agent-id <id> --search <TERM> [--inactive]
```

The script will prompt `Remove N server(s)? (yes/no):` — let it ask. Do not pass any flag to bypass it.

## Step 5 — Verify

Re-run the search to confirm the servers are gone:
```
python list_servers.py --search <TERM> --agent-id <id>
```

Report the count: *"Search now returns 0 matches on agent `<id>` — removal confirmed."*
