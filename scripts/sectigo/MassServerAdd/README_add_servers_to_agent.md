# Sectigo Mass Server Add — SSL Cert Renewal Toolset

A collection of Python scripts for bulk-registering IIS servers with Sectigo SCM
Network Agents and auditing certificate deployment across ~80 AWS accounts.

Built for the annual ASPGov SSL cert renewal cycle. The workflow migrates servers
from the old multi-SAN `*.aspgov.com` cert to per-client split certs
(`*.{client}cloud.aspgov.com`) and confirms the migration is complete.

---

## Scripts at a Glance

| Script | Purpose |
|--------|---------|
| `verify_accounts.py` | Confirm AWS SSO profiles are valid before any bulk run |
| `verify_domains.py` | SSM into instances to confirm local AD domain names match the CSV |
| `build_server_list.py` | Discover EC2 instances by name filter and write a Sectigo import JSON |
| `add_servers_to_agent.py` | POST one or more servers to a Sectigo Network Agent |
| `batch_add_servers.py` | Drive `build_server_list` + `add_servers_to_agent` across all CSV accounts |
| `get_cert_locations.py` | Export the server locations for a single cert to CSV |
| `audit_split_certs.py` | Report which servers on the old `*.aspgov.com` cert have/haven't migrated |
| `list_agent_nodes.py` | Flat list of every server node on both agents with cert name and order number |
| `verify_iis_certs.py` | SSM into each server and confirm the expected cert is bound in IIS |

---

## Requirements

- **Python 3.8+** — `python --version` to check (Windows: `python`, not `python3`)
- **boto3** — required by `batch_add_servers.py`, `verify_accounts.py`,
  `verify_domains.py`, and `verify_iis_certs.py`

  ```powershell
  pip install boto3
  ```

- All other scripts use only the Python standard library — no extra packages.

### Environment variables (all Sectigo scripts)

```powershell
$env:SECTIGO_LOGIN        = 'your_scm_username'
$env:SECTIGO_PASSWORD     = 'your_scm_password'
$env:SECTIGO_CUSTOMER_URI = 'centralsquare'
# Optional — only if your base URL differs:
$env:SECTIGO_BASE_URL     = 'https://cert-manager.com'
```

### AWS credentials

Scripts that call AWS use boto3 profile-based auth (AWS SSO). Profiles must be
configured in `~/.aws/config` and active (`aws sso login --profile <name>`).

### Network agents

| Region | Agent ID |
|--------|----------|
| us-east-1 | 18227 |
| us-west-2 | 18247 |

### Tracking spreadsheet

`ASPGOV_SSLCertRenewal_2026-2027.csv` — master list of all client SANs.
Key columns:

| Column | Meaning |
|--------|---------|
| `SAN` | Certificate subject alternative name (e.g. `*.ancocloud.aspgov.com`) |
| `In Use?` | `yes` = account is active, process it |
| `split cert already created?` | `yes` = a split cert has been issued in Sectigo |
| `us-east-1 or us-west-2` | Which region (and therefore which agent) this account uses |
| `client_id` | Short client code (e.g. `ANCO`) |
| `aws_profile` | AWS SSO profile name (e.g. `PALegacyFinEntANCO`) |
| `local_domain` | AD domain used for FQDN construction (e.g. `anco.cloud.lcl`) |
| `servers_added` | `yes` = servers already imported into Sectigo for this account |
| `name_filters` | Comma-separated EC2 Name-tag substrings to include. FinEnt accounts use `onsjb,onsap,onsrp,onsol,pxsf` plus `trkwb,etawb` where applicable. Non-FinEnt accounts (Plus, NaviLine, etc.) use their own filters. **Required** — rows with an empty `name_filters` will match no instances. |

---

## Workflow

### Phase 1 — Import servers into Sectigo Network Agents

Run once per account group to register servers so they can receive certs.

**Step 1: Verify AWS profiles**

```powershell
python verify_accounts.py
```

Checks every `In Use? = yes` row: confirms the AWS SSO profile is valid and
credentials are not expired. Fix any `FAIL` rows before proceeding.

**Step 2: Verify local domain names**

```powershell
python verify_domains.py
```

SSMs into one running instance per account and runs
`(Get-WmiObject Win32_ComputerSystem).Domain` to confirm the `local_domain`
value in the CSV is correct. Correct any `MISMATCH` rows before proceeding.

**Step 3: Dry-run the import**

```powershell
$env:SECTIGO_SVC_PASSWORD = "password-from-npm"

# All accounts in CSV
python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD --dry-run

# Single account
python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD --profile PALegacyFinEntANCO --dry-run
```

Review the output. Confirm the right servers are discovered and FQDNs look correct.

**Step 4: Import**

```powershell
python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD

# Single account
python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD --profile PALegacyFinEntANCO
```

Writes a timestamped report: `sectigo_servers_added_YYYYMMDD_HHMMSS.csv`.
Output files `servers_*.json` contain plaintext credentials — delete them after the run.

---

### Phase 2 — Audit certificate deployment

After split certs have been issued and auto-installed, use these scripts to
confirm every server has migrated off the old `*.aspgov.com` cert.

**Audit migration status (primary tool)**

```powershell
python audit_split_certs.py
```

- Fetches all server FQDNs from old cert 14546938 (what the agent currently sees)
- For every in-use client SAN, searches Sectigo for the split cert and fetches its location list
- Reports per server:

  | Status | Meaning |
  |--------|---------|
  | `MIGRATED` | Server appears in split cert locations — agent found the new cert |
  | `STILL_OLD_CERT` | Server NOT in any split cert — old cert still bound |
  | `NO_SPLIT_CERT` | No split cert found in Sectigo yet for this account |
  | `NO_CSV_MATCH` | FQDN doesn't match any `local_domain` in the CSV |

- Writes `audit_split_certs_YYYYMMDD_HHMMSS.csv`
- Exits non-zero if any `STILL_OLD_CERT` entries are found

**Full node inventory (by agent)**

```powershell
python list_agent_nodes.py
```

Paginates through all certs on both agents (18227 + 18247), fetches locations
and order numbers for each cert, and writes a flat report:

```
server_fqdn, cert_common_name, order_number, cert_id, agent_id, agent_name
```

Also prints to console any server showing up under **multiple certs** — these
are servers mid-migration that still have both old and new certs bound.

Output: `agent_nodes_YYYYMMDD_HHMMSS.csv`

**Export locations for a specific cert**

```powershell
python get_cert_locations.py --cert-id 14546938
python get_cert_locations.py --cert-id 15020263 --debug
```

Writes `cert_locations_{cert_id}_{timestamp}.csv`.
Use `--debug` to dump the raw API response when locations look wrong.

**Verify IIS bindings via SSM (optional deep check)**

```powershell
python verify_iis_certs.py --cert-id 15020263
```

For every server in a cert's location list, SSMs in and queries `IIS:\SslBindings`
to confirm the correct cert thumbprint is actually bound. Requires SSM online.
Writes `verify_iis_certs_{cert_id}_{timestamp}.csv`.

---

## Script Reference

### `add_servers_to_agent.py`

Low-level script. POSTs one or more servers from a JSON file to a Sectigo
Network Agent.

```powershell
# Dry run
python add_servers_to_agent.py --agent-id 18227 servers.json --dry-run

# Real run
python add_servers_to_agent.py --agent-id 18227 servers.json
```

See `example_servers.json` for the input file format.

Exit codes: `0` = all succeeded, `1` = partial failure, `2` = input validation error.

### `build_server_list.py`

Discovers EC2 instances by Name-tag substring across regions and writes a
Sectigo-formatted JSON for `add_servers_to_agent.py`. Called automatically
by `batch_add_servers.py`.

```powershell
python build_server_list.py `
  --profile PALegacyFinEntANCO `
  --domain anco.cloud.lcl `
  --username "CLOUD\sectigo_svc" `
  --password-env SECTIGO_SVC_PASSWORD `
  --output-prefix servers_anco `
  --name-filters onsjb,onsap,onsrp,onsol,pxsf `
  --dry-run
```

Produces per-region files: `servers_anco_us-east-1.json`, `servers_anco_us-west-2.json`.
Delete output files after import — they contain plaintext passwords.

### `batch_add_servers.py`

Runs the full build → add pipeline for every qualifying row in the CSV.
Requires `--password-env` pointing to an env var holding the `CLOUD\sectigo_svc` password (retrieve from NPM).

```powershell
# All qualifying accounts
python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD

# Single account
python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD --profile PALegacyFinEntBRENT

# Dry run (no API calls; --password-env still required but value not used)
python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD --dry-run
```

Qualifying rows: `In Use? = yes`, `servers_added` not `yes`.

Report columns: `account, san, fqdn, region, agent_id, status, message`.

### `verify_accounts.py`

```powershell
python verify_accounts.py
python verify_accounts.py --skip-dns
```

Reports: `OK`, `WARN` (DNS check failed), `FAIL` (auth failed).

### `verify_domains.py`

```powershell
python verify_domains.py
python verify_domains.py --profile PALegacyFinEntANCO
```

Reports: `Match`, `Mismatch`, `No SSM`, `Auth fail`.
Tries all matching instances per account until one SSM-reachable instance is found.

---

## Security Notes

- **Never commit `servers_*.json` files** — they contain plaintext server passwords.
  These are gitignored. Delete them after each import run.
- `sectigo_servers_added_*.csv` report files are also gitignored.
- Sectigo credentials are read from environment variables only — never from files
  or command-line arguments.
- The service account password (`SECTIGO_SVC_PASSWORD`) must be set as an
  environment variable before running `build_server_list.py` or `batch_add_servers.py`.
  Retrieve it from the NPM password manager.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Missing required environment variable: SECTIGO_LOGIN` | Set the three Sectigo env vars in the current shell |
| `HTTP 401` | Wrong `login`, `password`, or `customerUri` |
| `HTTP 404` on agent endpoint | Agent ID doesn't exist or account lacks access |
| `HTTP 400 code:-6009` | `port` missing for a remote connection type |
| `ProfileNotFound` | Run `aws sso login --profile <name>` |
| `ForbiddenException` from AWS | Profile config issue — check `~/.aws/config` |
| `python3` not found | Use `python` on Windows |
| `servers_*.json` not generated | Check `--dry-run` isn't set, and that `SECTIGO_SVC_PASSWORD` is set |
