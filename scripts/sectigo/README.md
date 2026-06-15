# scripts/sectigo — Sectigo SCM Certificate Management

Python automation for Sectigo SCM (cert-manager.com) bulk operations.

**Pre-requisite:** Credentials must be set as environment variables before running either tool — never hard-coded. See each tool's section below.

## Tools

| Script / Folder | Kiro Task | Purpose |
|-----------------|-----------|---------|
| `MassCertRevoke/` | `Sectigo: Mass Cert Revoke` | Revoke SSL certificates in bulk by ID |
| `MassServerAdd/` | `Sectigo: Mass Server Add` | Bulk-register servers with a Sectigo Network Agent |
| `aspgov-cert-management/` | — | F5 XC and c2g Apache cert renewal scripts for ASPGov |

---

## MassCertRevoke

Revokes Sectigo SCM SSL certificates by ID via `POST /api/ssl/v2/revoke/{id}`.

**Credentials (env vars required):**

```bash
export SECTIGO_LOGIN='your_user'
export SECTIGO_PASSWORD='your_pass'
export SECTIGO_CUSTOMER_URI='your_customer_uri'
export SECTIGO_BASE_URL='https://cert-manager.com'   # optional, this is the default
```

**Usage:**

```bash
python revoke_certs.py ids.json
python revoke_certs.py ids.json --reason "Key rotation" --reason-code 1
echo '[123, 456]' | python revoke_certs.py -
```

`ids.json` contains a JSON array of integer certificate IDs. The included `ids.json` is a template — populate it before running.

**Reason codes (Mozilla Root Store Policy):**

| Code | Meaning |
|------|---------|
| 0 | unspecified |
| 1 | keyCompromise |
| 3 | affiliationChanged |
| 4 | superseded |
| 5 | cessationOfOperation |

---

## MassServerAdd

Bulk-registers servers with a Sectigo SCM Network Agent via `POST /api/agent/v1/network/{agentId}/server`.

See [`MassServerAdd/README_add_servers_to_agent.md`](MassServerAdd/README_add_servers_to_agent.md) for full usage, required env vars, and `servers_input.json` format.

---

## Sectigo MCP Server (Claude Code integration)

`mcp_proxy.py` is a stdio proxy that bridges Claude Code to the hosted Sectigo MCP server at
`https://mcp.enterprise.sectigo.com/mcp`. Once configured, Claude can list, inspect, enroll,
renew, and revoke certificates directly from a conversation — no browser required.

### How it works

The proxy uses OAuth 2.0 client credentials to obtain a short-lived Bearer token from Sectigo's
auth server, forwards each JSON-RPC message from Claude Code to the hosted MCP endpoint, and
streams the response back. Tokens are refreshed automatically 30 seconds before expiry.

### Setup

**1. Get OAuth credentials from SCM**

In the Sectigo SCM admin console, create an API client and note the **Client ID** and
**Client Secret**. These must be present as environment variables before Claude Code starts —
never hard-coded in any file.

**2. Set the environment variables**

Add to your shell profile (PowerShell `$PROFILE`) or a `.env` loader:

```powershell
$env:SECTIGO_CLIENT_ID     = 'your-client-id'
$env:SECTIGO_CLIENT_SECRET = 'your-client-secret'
```

> These values must be set in the session that launches Claude Code (or Kiro). The proxy reads
> them at startup and will exit with a clear error if either is missing.

**3. Enable the MCP server**

The repo ships a `.mcp.json` at the root that registers `mcp_proxy.py` as the `sectigo` MCP
server. Claude Code loads it automatically when `enableAllProjectMcpServers` is set in
`.claude/settings.json` (already configured in this repo).

You can verify the server is connected by running `/mcp` in a Claude Code session — `sectigo`
should appear in the list with a green status.

**4. Use it**

Once connected, Claude can handle certificate workflows conversationally. Examples:

```
List all certificates expiring in the next 30 days.
Find the certificate for api.example.com and show its SANs.
Renew cert ID 12345.
What certificates are in Requested status and need approval?
```

The MCP tools available are the same as the `mcp__sectigo__*` tools listed in `.claude/settings.json`.

### Credentials never leave the proxy

The Bearer token is held in memory inside `mcp_proxy.py` and is never written to disk, logged,
or included in any tool output. The proxy exits cleanly if credentials are invalid or the token
endpoint is unreachable.
