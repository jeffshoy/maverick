# scripts/sectigo — Sectigo SCM Certificate Management

Python automation for Sectigo SCM (cert-manager.com) bulk operations.

**Pre-requisite:** Credentials must be set as environment variables before running either tool — never hard-coded. See each tool's section below.

## Tools

| Script / Folder | Kiro Task | Purpose |
|-----------------|-----------|---------|
| `MassCertRevoke/` | `Sectigo: Mass Cert Revoke` | Revoke SSL certificates in bulk by ID |
| `MassServerAdd/` | `Sectigo: Mass Server Add` | Bulk-register servers with a Sectigo Network Agent |

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
