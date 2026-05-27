#!/usr/bin/env python3
"""Export the server locations for a Sectigo certificate to CSV.

Queries the Sectigo SCM API for a certificate's deployment locations (the
servers listed under the cert in SCM) and writes them to a timestamped CSV.

Use this to verify all servers on an old multi-SAN cert before revoking it.

Usage:
  # Export locations for cert ID 14546938:
  python get_cert_locations.py --cert-id 14546938

  # If output looks wrong, dump raw API response to diagnose:
  python get_cert_locations.py --cert-id 14546938 --debug

Required environment variables (same as other Sectigo scripts):
  SECTIGO_LOGIN, SECTIGO_PASSWORD, SECTIGO_CUSTOMER_URI
Optional:
  SECTIGO_BASE_URL  (default: https://cert-manager.com)
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Any

import urllib.error
import urllib.request


@dataclass(frozen=True)
class Credentials:
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
                base_url=os.environ.get(
                    "SECTIGO_BASE_URL", "https://cert-manager.com"
                ).rstrip("/"),
            )
        except KeyError as missing:
            sys.exit(
                f"Missing required environment variable: {missing.args[0]}. "
                "Set SECTIGO_LOGIN, SECTIGO_PASSWORD, and SECTIGO_CUSTOMER_URI."
            )


def api_get(url: str, creds: Credentials) -> Any:
    """GET a Sectigo API endpoint and return the parsed JSON body."""
    req = urllib.request.Request(url, method="GET")
    req.add_header("login", creds.login)
    req.add_header("password", creds.password)
    req.add_header("customerUri", creds.customer_uri)
    req.add_header("Accept", "application/json")

    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        sys.exit(f"HTTP {e.code} from {url}: {body[:500]}")
    except urllib.error.URLError as e:
        sys.exit(f"Network error reaching {url}: {e.reason}")


def get_cert_details(cert_id: int, creds: Credentials) -> dict:
    """Fetch the top-level certificate record."""
    url = f"{creds.base_url}/api/ssl/v2/{cert_id}"
    return api_get(url, creds)


def get_cert_locations(cert_id: int, creds: Credentials) -> list[dict]:
    """Fetch the deployment locations for a certificate.

    Sectigo exposes locations at /api/ssl/v2/{id}/renewalInfo or via the
    agent network API. We try the most likely endpoints in order and return
    the first one that yields a non-empty list.
    """
    candidates = [
        f"{creds.base_url}/api/ssl/v2/{cert_id}/renewalInfo",
        f"{creds.base_url}/api/agent/v1/ssl/{cert_id}/location",
        f"{creds.base_url}/api/ssl/v2/{cert_id}/location",
    ]

    for url in candidates:
        try:
            data = api_get(url, creds)
            # Accept a list directly or a dict with a locations/items/data key
            if isinstance(data, list) and data:
                return data
            if isinstance(data, dict):
                for key in ("locations", "items", "data", "servers"):
                    if isinstance(data.get(key), list) and data[key]:
                        return data[key]
        except SystemExit:
            # api_get calls sys.exit on HTTP errors — catch so we can try next
            continue

    return []


def flatten_location(loc: dict, cert_id: int, cert_details: dict) -> dict:
    """Normalize a location record to a flat dict for CSV output."""
    # Common field names Sectigo uses across API versions
    return {
        "cert_id": cert_id,
        "cert_cn": cert_details.get("commonName", ""),
        "cert_status": cert_details.get("status", ""),
        "cert_expiry": cert_details.get("notAfter", ""),
        "server_name": (
            loc.get("name") or loc.get("serverName") or loc.get("hostname") or ""
        ),
        "server_ip": (
            loc.get("ip") or loc.get("ipAddress") or loc.get("host") or ""
        ),
        "location_id": loc.get("id") or loc.get("locationId") or "",
        "agent_id": loc.get("agentId") or loc.get("networkId") or "",
        "status": loc.get("status") or loc.get("deploymentStatus") or "",
        "last_updated": loc.get("lastUpdated") or loc.get("updatedAt") or "",
    }


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Export Sectigo certificate deployment locations to CSV.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--cert-id",
        type=int,
        required=True,
        help="Sectigo certificate ID to query (e.g. 14546938).",
    )
    p.add_argument(
        "--output",
        default=None,
        help=(
            "Output CSV path. Defaults to "
            "cert_locations_<cert_id>_<timestamp>.csv in the current directory."
        ),
    )
    p.add_argument(
        "--debug",
        action="store_true",
        help="Dump raw API responses to stdout for diagnosis.",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    creds = Credentials.from_env()

    print(f"Fetching certificate {args.cert_id} from {creds.base_url}...")

    cert = get_cert_details(args.cert_id, creds)

    if args.debug:
        print("\n--- Certificate details (raw) ---")
        print(json.dumps(cert, indent=2))

    cn = cert.get("commonName", "unknown")
    status = cert.get("status", "unknown")
    expiry = cert.get("notAfter", "unknown")
    sans = cert.get("subjectAltNames", [])

    print(f"  CN      : {cn}")
    print(f"  Status  : {status}")
    print(f"  Expiry  : {expiry}")
    print(f"  SANs    : {len(sans)}")
    print()

    print("Fetching deployment locations...")
    locations = get_cert_locations(args.cert_id, creds)

    if args.debug:
        print("\n--- Locations (raw) ---")
        print(json.dumps(locations, indent=2))

    if not locations:
        print(
            "No locations returned from API.\n"
            "Re-run with --debug to see the raw response and check field names.\n"
            "The locations may be embedded in the cert details above."
        )
        # If debug, check if cert details itself has location-like fields
        if args.debug:
            for key in cert:
                val = cert[key]
                if isinstance(val, list) and val:
                    print(f"\nNote: cert details has non-empty list field '{key}':")
                    print(json.dumps(val[:3], indent=2), "..." if len(val) > 3 else "")
        sys.exit(0)

    print(f"Found {len(locations)} location(s).")

    rows = [flatten_location(loc, args.cert_id, cert) for loc in locations]

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = args.output or f"cert_locations_{args.cert_id}_{timestamp}.csv"

    fieldnames = [
        "cert_id", "cert_cn", "cert_status", "cert_expiry",
        "server_name", "server_ip", "location_id", "agent_id",
        "status", "last_updated",
    ]
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Written to : {out_path}")
    print()
    print("Servers found:")
    col_w = max((len(r["server_name"]) for r in rows), default=10) + 2
    for r in sorted(rows, key=lambda x: x["server_name"]):
        print(f"  {r['server_name']:<{col_w}}  {r['server_ip']}")


if __name__ == "__main__":
    main()
