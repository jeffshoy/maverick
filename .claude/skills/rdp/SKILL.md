---
name: rdp
description: RDP to an EC2 instance via SSM port forwarding. Use when the user asks to RDP / connect / remote into a server by name in a named AWS account (e.g. "rdp to INF-PLOGIC018 in plus", "/rdp cld-pplsapm001 sharedservices"). Parses server name and account from natural language and runs scripts/aws/Connect-RDP.ps1.
---

# /rdp — RDP to an EC2 instance via SSM

Parse the user's input to extract a server name and an account, then run Connect-RDP.ps1.

## Parsing

- **Server name**: the EC2 Name-tag-style token (e.g. INF-PLOGIC018, CLD-PPLSAPM001, ARCT-PTRKRD001). Normalize to uppercase.
- **Account**: any nickname or account name (plus, PLUS, PALegacyPlus, sharedservices, analytics, cogwb, etc.). Pass as-is — Connect-RDP.ps1 does fuzzy resolution via aws-configs/accounts.json.
- If either piece is missing or genuinely ambiguous, ask before running.

## Action

Run via the Bash tool from the cloudops repo root:

```
pwsh scripts/aws/Connect-RDP.ps1 -ServerName <SERVER> -Account <ACCOUNT>
```

Do not add flags unless the user asks (e.g. `-NoLaunch`, `-NoCache`).

## Examples

- "rdp to inf-plogic018 in the plus prod account" → `-ServerName INF-PLOGIC018 -Account plus`
- "/rdp cld-pplsapm001 sharedservices"            → `-ServerName CLD-PPLSAPM001 -Account sharedservices`
- "connect to arct-ptrkrd001 analytics"            → `-ServerName ARCT-PTRKRD001 -Account analytics`

## Reporting

After the script runs, report only what resolved (account name, instance ID, region) from its output. The script handles SSO refresh, instance lookup/cache, port selection, the SSM tunnel, and mstsc launch automatically — no commentary needed beyond confirming the connection.
