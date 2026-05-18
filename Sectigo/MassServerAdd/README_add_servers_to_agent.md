# Add Servers to a Sectigo Network Agent

A small Python script for bulk-registering one or more servers with an existing
Sectigo SCM **Network Agent**. Wraps the official endpoint:

```
POST /api/agent/v1/network/{agentId}/server
```

API reference: <https://scm.devx.sectigo.com/reference/add-server-to-network-agent>

---

## Requirements

### Python

- **Python 3.8 or newer** (CPython). Tested on 3.8, 3.10, 3.11, and 3.12.
- Python 3.7 will *not* work — the script uses syntax and standard-library
  behavior introduced in 3.8.
- Check your version with `python3 --version`.

### Third-party packages

**None.** The script uses only modules from the Python standard library:

| Module               | Purpose                                |
| -------------------- | -------------------------------------- |
| `argparse`           | command-line argument parsing          |
| `dataclasses`        | typed credentials container            |
| `json`               | reading the input file, building bodies, parsing API errors |
| `os`                 | reading credentials from environment variables |
| `sys`                | exit codes, stdin / stderr             |
| `urllib.request` / `urllib.error` | HTTPS calls to the Sectigo API |

There is nothing to `pip install`, no virtual environment to create, and no
`requirements.txt` to manage.

### Operating system

Runs on Linux, macOS, and Windows — any platform with a supported Python
build. No OS-specific commands are invoked.

### Sectigo / network

- Outbound HTTPS (TCP 443) reachability to your Sectigo SCM host
  (default: `https://cert-manager.com`). If your environment requires a
  proxy, set the standard `HTTPS_PROXY` environment variable before running
  the script — `urllib` honors it automatically.
- An SCM account with permission to manage Network Agents, and the
  `customerUri` value for your SCM tenant.

---

## Setup

### 1. Download the script

Place `add_servers_to_agent.py` anywhere on the machine that will run it.

### 2. Set authentication environment variables

The script uses Sectigo's **legacy header authentication** (`login` /
`password` / `customerUri`). Credentials are read from environment variables so
they are never visible on the command line or in shell history.

```sh
export SECTIGO_LOGIN='your_scm_username'
export SECTIGO_PASSWORD='your_scm_password'
export SECTIGO_CUSTOMER_URI='your_customer_uri'
```

Optional — override only if Sectigo has provisioned you a non-default host:

```sh
export SECTIGO_BASE_URL='https://cert-manager.com'
```

On Windows PowerShell:

```powershell
$env:SECTIGO_LOGIN = 'your_scm_username'
$env:SECTIGO_PASSWORD = 'your_scm_password'
$env:SECTIGO_CUSTOMER_URI = 'your_customer_uri'
```

---

## Input file format

The script reads a single JSON file. That file must contain **either** one
server object **or** a JSON array of server objects.

### Single server

```json
{
  "name": "web01.example.com",
  "vendor": "APACHE_2",
  "connectionType": "REMOTE_SSH",
  "ip": "10.0.0.21",
  "port": 22,
  "username": "deploy",
  "password": "REPLACE_ME",
  "path": "/usr/sbin/apachectl"
}
```

### Multiple servers (bulk)

```json
[
  {
    "name": "web01.example.com",
    "vendor": "APACHE_2",
    "connectionType": "REMOTE_SSH",
    "ip": "10.0.0.21",
    "port": 22,
    "username": "deploy",
    "password": "REPLACE_ME"
  },
  {
    "name": "iis01.corp.local",
    "vendor": "IIS",
    "connectionType": "REMOTE_WIN_RM",
    "ip": "10.0.0.30",
    "port": 5985,
    "username": "svc-sectigo",
    "password": "REPLACE_ME"
  }
]
```

### F5 BIG-IP (REST API)

F5 BIG-IP is **always** managed via its iControl REST API, so `connectionType`
must be `REMOTE_REST_API` and `port` is required (443 in almost all
deployments). The script enforces this combination — any other
`connectionType` paired with `F5_BIG_IP` will fail local validation.

```json
{
  "name": "f5-lb01.example.com",
  "vendor": "F5_BIG_IP",
  "connectionType": "REMOTE_REST_API",
  "ip": "10.0.0.50",
  "port": 443,
  "username": "sectigo-api",
  "password": "REPLACE_ME"
}
```

Notes:

- The `username` / `password` must be a service account on the BIG-IP that has
  permission to read and replace certificates via iControl REST.
- The account typically needs the **Certificate Manager** role (or equivalent)
  on the relevant partition.

### IIS over remote legacy native API

For IIS specifically, the `REMOTE_LEGACY_NATIVE_API` connection type does
**not** require a `port` — the SCM web UI omits the field for this exact
combination and the API accepts the request without it.

```json
{
  "name": "iis-legacy01.corp.local",
  "vendor": "IIS",
  "connectionType": "REMOTE_LEGACY_NATIVE_API",
  "ip": "10.0.0.31",
  "username": "svc-sectigo",
  "password": "REPLACE_ME"
}
```

### Field reference

| Field            | Type    | Required                                   | Notes                                                                                  |
| ---------------- | ------- | ------------------------------------------ | -------------------------------------------------------------------------------------- |
| `name`           | string  | **Yes**                                    | Display name for the server. 1–512 characters, must not be blank.                      |
| `vendor`         | string  | **Yes**                                    | One of `APACHE_2`, `IIS`, `TOMCAT`, `F5_BIG_IP`.                                       |
| `connectionType` | string  | No                                         | One of `LOCAL`, `LOCAL_LEGACY_NATIVE_API`, `REMOTE_REST_API`, `REMOTE_SSH`, `REMOTE_WIN_RM`, `REMOTE_LEGACY_NATIVE_API`. |
| `ip`             | string  | Required for remote connections            | Hostname or IP of the target server.                                                   |
| `port`           | int     | Required for remote connections (one exception below) | Service port on the target server (e.g. 22 for SSH, 5985 HTTP / 5986 HTTPS for WinRM, 443 for REST). **Exception:** when `vendor` is `IIS` and `connectionType` is `REMOTE_LEGACY_NATIVE_API`, the port is *not* required (the SCM UI itself omits the field). All other remote combinations — including IIS over WinRM — must include a port, otherwise the API returns error `-6009`. |
| `path`           | string  | No                                         | Tomcat root dir, or path to the `apachectl` executable for Apache.                     |
| `altPathForCert` | string  | No                                         | Alternative directory where the server stores certificates.                            |
| `privateKeyPath` | string  | No                                         | Directory where the Network Agent stores the private key.                              |
| `passPhrase`     | string  | No                                         | Keystore passphrase, if applicable.                                                    |
| `username`       | string  | No                                         | Login used by the agent to reach the server (≤ 64 characters).                         |
| `password`       | string  | No                                         | Password for the above username.                                                       |
| `storeName`      | string  | No                                         | Store name for keystore-based access.                                                  |
| `storeCredId`    | string  | No                                         | Store credential ID for keystore-based access.                                         |

The script rejects any field name not in this list, so typos like
`connection_type` (snake_case) or `Vendor` (wrong case) will be reported before
any request is sent.

---

## Usage

### Validate without sending (recommended first run)

```sh
python add_servers_to_agent.py --agent-id 1234 servers.json --dry-run
```

`--dry-run` parses and validates the input file and prints the requests that
*would* be sent. Passwords and pass-phrases are redacted in this output, so the
log is safe to share for troubleshooting.

### Add the servers for real

```sh
python add_servers_to_agent.py --agent-id 1234 servers.json
```

Where `1234` is the **Network Agent ID** that the servers should be attached
to. You can find this ID in the SCM web UI under *Discovery → Network Agents*.

### Example output

```
Adding 2 server(s) to agent 1234 via https://cert-manager.com...
[OK  ] web01.example.com: created (id=88102)
[FAIL] iis01.corp.local: HTTP 400: {"code":-1402,"description":"..."}

Done. 1 succeeded, 1 failed.
```

The script exits with:

- `0` — every server was added successfully.
- `1` — one or more servers failed (details printed above the summary).
- `2` — the input file failed local validation; no requests were sent.

---

## Troubleshooting

| Symptom                                                | Likely cause / fix                                                                       |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `Missing required environment variable: SECTIGO_LOGIN` | One of the three required env vars is not set in the current shell.                      |
| `HTTP 401`                                             | `login`, `password`, or `customerUri` is incorrect, or the account lacks API access.     |
| `HTTP 404`                                             | The `--agent-id` does not exist, or your account does not have access to it.             |
| `HTTP 400` with a field name                           | The Sectigo API rejected a field value. Re-check enum spelling and field constraints.    |
| `HTTP 400 code:-6009 "Target server requires host and port configuration"` | The server's `connectionType` is remote but `port` is missing. Add a `port` field (e.g. `5985` for WinRM, `22` for SSH, `443` for REST). |
| `network error`                                        | The host in `SECTIGO_BASE_URL` is unreachable. Check firewall / proxy / DNS.             |

---

## Security notes

- Credentials never appear on the command line — they are read only from
  environment variables.
- `--dry-run` output redacts `password` and `passPhrase` fields.
- The input JSON file may contain server credentials. Store it on an
  appropriately restricted filesystem and delete it after a successful run.
- The script makes only outbound HTTPS requests to the configured
  `SECTIGO_BASE_URL` (default `https://cert-manager.com`).
