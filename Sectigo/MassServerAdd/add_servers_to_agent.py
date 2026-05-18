#!/usr/bin/env python3
"""Add one or more servers to a Sectigo SCM Network Agent.

Reads a JSON file describing the servers to register and POSTs each one to:
    POST /api/agent/v1/network/{agentId}/server

Authentication uses the legacy header method (login / password / customerUri),
which is supported on the cert-manager.com host. Credentials are taken from
environment variables so they never appear on the command line or in shell
history.

The input JSON file must contain either:
  * A single server object, e.g. {"name": "...", "vendor": "APACHE_2", ...}
  * A JSON array of such objects (for bulk registration)

Each object's fields map 1:1 onto the Sectigo request body. See README.md for
the full field reference.

Run `python add_servers_to_agent.py --help` for CLI usage.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Any

import urllib.error
import urllib.request


# Enum values copied verbatim from the Sectigo API spec. We validate against
# them client-side so a typo doesn't waste a round-trip (and so the error
# message points at the offending field instead of a generic HTTP 400).
ALLOWED_VENDORS = {"APACHE_2", "IIS", "TOMCAT", "F5_BIG_IP"}
ALLOWED_CONNECTION_TYPES = {
    "LOCAL",
    "LOCAL_LEGACY_NATIVE_API",
    "REMOTE_REST_API",
    "REMOTE_SSH",
    "REMOTE_WIN_RM",
    "REMOTE_LEGACY_NATIVE_API",
}

# Every field the Sectigo "add server" body accepts. Used to reject unknown
# keys early so the customer sees "did you mean X?" instead of a silent drop.
KNOWN_FIELDS = {
    "name",
    "vendor",
    "connectionType",
    "ip",
    "port",
    "path",
    "altPathForCert",
    "privateKeyPath",
    "passPhrase",
    "username",
    "password",
    "storeName",
    "storeCredId",
}


@dataclass(frozen=True)
class Credentials:
    """Holds the auth headers and base URL needed for every request."""

    login: str
    password: str
    customer_uri: str
    base_url: str

    @classmethod
    def from_env(cls) -> "Credentials":
        try:
            return cls(
                login=os.environ["SECTIGO_LOGIN"],
                password=os.environ["SECTIGO_PASSWORD"],
                customer_uri=os.environ["SECTIGO_CUSTOMER_URI"],
                # cert-manager.com is the host that accepts legacy header auth.
                # Override only if Sectigo has provisioned you a different one.
                base_url=os.environ.get(
                    "SECTIGO_BASE_URL", "https://cert-manager.com"
                ).rstrip("/"),
            )
        except KeyError as missing:
            sys.exit(
                f"Missing required environment variable: {missing.args[0]}. "
                "Set SECTIGO_LOGIN, SECTIGO_PASSWORD, and SECTIGO_CUSTOMER_URI "
                "before running this script."
            )


def load_servers(path: str) -> list[dict[str, Any]]:
    """Parse the input JSON file and normalize it to a list of server dicts."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        sys.exit(f"Input file not found: {path}")
    except json.JSONDecodeError as e:
        sys.exit(f"Input file is not valid JSON: {e}")

    # Accept either a single object or a list of objects so the customer can
    # use the same script for one-off additions and bulk imports.
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list) or not all(isinstance(x, dict) for x in data):
        sys.exit("Input must be a JSON object or an array of JSON objects.")
    if not data:
        sys.exit("Input file contains no server definitions.")

    return data


def validate_server(server: dict[str, Any], index: int) -> list[str]:
    """Return a list of human-readable validation errors for one server.

    An empty list means the server passed all client-side checks. We catch
    obvious mistakes (missing required fields, unknown enums, wrong types)
    here so the customer gets a clear error message before the request is
    sent.
    """
    errors: list[str] = []
    prefix = f"server[{index}]"

    # Required fields per the API spec.
    name = server.get("name")
    if not isinstance(name, str) or not name.strip():
        errors.append(f"{prefix}.name is required and must be a non-blank string.")
    elif len(name) > 512:
        errors.append(f"{prefix}.name must be 1-512 characters.")

    vendor = server.get("vendor")
    if vendor not in ALLOWED_VENDORS:
        errors.append(
            f"{prefix}.vendor is required and must be one of "
            f"{sorted(ALLOWED_VENDORS)} (got {vendor!r})."
        )

    # Optional enum, only validated if present.
    conn = server.get("connectionType")
    if conn is not None and conn not in ALLOWED_CONNECTION_TYPES:
        errors.append(
            f"{prefix}.connectionType must be one of "
            f"{sorted(ALLOWED_CONNECTION_TYPES)} (got {conn!r})."
        )

    # F5 BIG-IP is always managed via its iControl REST API. Any other
    # connectionType is misconfiguration and will fail at the agent.
    if vendor == "F5_BIG_IP" and conn is not None and conn != "REMOTE_REST_API":
        errors.append(
            f"{prefix}.connectionType must be 'REMOTE_REST_API' for "
            f"F5_BIG_IP (got {conn!r})."
        )

    # The spec marks `ip` and `port` as "required for a remote server". The
    # one confirmed exception is IIS over REMOTE_LEGACY_NATIVE_API, where the
    # SCM UI itself omits the port field — every other remote combination
    # (including IIS over REMOTE_WIN_RM) needs a port, otherwise the API
    # returns error -6009 ("Target server requires host and port
    # configuration").
    if isinstance(conn, str) and conn.startswith("REMOTE"):
        if not server.get("ip"):
            errors.append(f"{prefix}.ip is required for remote connection types.")
        port_exempt = vendor == "IIS" and conn == "REMOTE_LEGACY_NATIVE_API"
        if not port_exempt and server.get("port") in (None, ""):
            errors.append(f"{prefix}.port is required for remote connection types.")

    # Typo guard: anything outside the documented field list is almost
    # certainly a mistake (e.g. "connection_type" vs "connectionType").
    unknown = set(server) - KNOWN_FIELDS
    if unknown:
        errors.append(
            f"{prefix} contains unknown field(s): {sorted(unknown)}. "
            f"Allowed fields: {sorted(KNOWN_FIELDS)}."
        )

    return errors


def add_server(
    agent_id: int, server: dict[str, Any], creds: Credentials
) -> tuple[bool, str]:
    """POST one server to the network agent. Returns (success, message)."""
    url = f"{creds.base_url}/api/agent/v1/network/{agent_id}/server"
    payload = json.dumps(server).encode("utf-8")

    req = urllib.request.Request(url, data=payload, method="POST")
    # Legacy Sectigo auth headers — these go in the request, not the URL.
    req.add_header("login", creds.login)
    req.add_header("password", creds.password)
    req.add_header("customerUri", creds.customer_uri)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")

    try:
        with urllib.request.urlopen(req) as resp:
            # 201 Created on success. Sectigo typically returns the new
            # server's ID in the Location header (e.g. ".../server/42").
            if resp.status == 201:
                location = resp.headers.get("Location", "")
                new_id = location.rstrip("/").rsplit("/", 1)[-1] if location else "?"
                return True, f"created (id={new_id})"
            body = resp.read().decode("utf-8", errors="replace")
            return True, f"HTTP {resp.status}: {body[:200]}"
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        return False, f"HTTP {e.code}: {body[:300]}"
    except urllib.error.URLError as e:
        return False, f"network error: {e.reason}"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Register servers with a Sectigo SCM Network Agent.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Required environment variables:\n"
            "  SECTIGO_LOGIN           SCM username\n"
            "  SECTIGO_PASSWORD        SCM password\n"
            "  SECTIGO_CUSTOMER_URI    SCM customer URI\n"
            "Optional:\n"
            "  SECTIGO_BASE_URL        defaults to https://cert-manager.com\n"
        ),
    )
    p.add_argument(
        "--agent-id",
        type=int,
        required=True,
        help="Network agent ID to add the servers to (path parameter).",
    )
    p.add_argument(
        "servers_file",
        help="Path to a JSON file containing a server object or list of objects.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate the input file and print the requests without sending them.",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    servers = load_servers(args.servers_file)

    # Validate every server up front. Failing fast on the whole file means
    # the customer fixes all typos in one edit instead of one at a time.
    all_errors: list[str] = []
    for i, srv in enumerate(servers):
        all_errors.extend(validate_server(srv, i))
    if all_errors:
        print("Validation failed:", file=sys.stderr)
        for err in all_errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(2)

    if args.dry_run:
        print(f"[dry-run] Would POST {len(servers)} server(s) to agent {args.agent_id}:")
        for srv in servers:
            # Redact secrets even in dry-run output so logs are safe to share.
            printable = {
                k: ("***" if k in ("password", "passPhrase") else v)
                for k, v in srv.items()
            }
            print(f"  - {json.dumps(printable)}")
        return

    creds = Credentials.from_env()
    print(
        f"Adding {len(servers)} server(s) to agent {args.agent_id} "
        f"via {creds.base_url}..."
    )

    failures = 0
    for i, srv in enumerate(servers):
        ok, msg = add_server(args.agent_id, srv, creds)
        label = srv.get("name", f"<index {i}>")
        status = "OK  " if ok else "FAIL"
        print(f"[{status}] {label}: {msg}")
        if not ok:
            failures += 1

    print(f"\nDone. {len(servers) - failures} succeeded, {failures} failed.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
