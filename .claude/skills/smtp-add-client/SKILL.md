---
name: smtp-add-client
description: Add a new client domain to the SMTP relay infrastructure. Creates an SES verified identity (or skips if already exists), outputs DKIM records for the customer, and adds the domain to relay_domains on both Postfix relays (us-east-1 and us-west-2). Use when onboarding a new client email domain (e.g. "/smtp-add-client cityofsolanabeach.ca.gov west", "/smtp-add-client clientdomain.com east").
---

# /smtp-add-client — Add a client domain to SES + Postfix relay

## Parsing

- **Domain**: the client's email domain (e.g. clientdomain.com)
- **Region**: `east` (us-east-1) or `west` (us-west-2) — determines which region the SES identity is created in
- If either is missing, ask before running.

## Action

Run via the Bash tool from the cloudops repo root:

```
pwsh scripts/smtp/Add-SmtpClient.ps1 -Domain <DOMAIN> -Region <east|west>
```

## Behaviour

1. Checks if SES identity already exists in the specified region
   - If yes: skips creation, reports current verification status, continues to relay step
   - If no: creates identity with Easy DKIM (RSA_2048_BIT, signatures enabled, Route53 disabled), outputs DKIM records
2. Adds domain to relay_domains on BOTH relays alphabetically, runs postmap and reloads postfix, validates on both
3. Reports full summary

## Infrastructure

- Account: PALegacySharedServices (361362055558, foundation, profile: PALegacySharedServices)
- Relay East: i-034b91ef8516afd72 (inf-relay001.cloud.lcl) — us-east-1
- Relay West: i-0be7224e91e5b785a (inf-relay101.cloud.lcl) — us-west-2
- SSM Parameter: /relay/svc-wsl-relay (SecureString, exists in both regions)
- WSL user: cloud\svc-wsl-relay

## Examples

- "/smtp-add-client cityofsolanabeach.ca.gov west" → SES in us-west-2, relay_domains on both relays
- "/smtp-add-client clientdomain.com east"         → SES in us-east-1, relay_domains on both relays
