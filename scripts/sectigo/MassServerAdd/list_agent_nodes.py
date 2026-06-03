#!/usr/bin/env python3
"""List all server nodes on Sectigo network agents with their associated cert.

Paginates through all certificates on both network agents (18227 east, 18247 west),
fetches the location list for each cert, and builds a flat server-centric report:

  server_fqdn | cert_common_name | order_number | cert_id | agent_id | agent_name

Usage:
  python list_agent_nodes.py
  python list_agent_nodes.py --output my_report.csv

Required env vars: SECTIGO_LOGIN, SECTIGO_PASSWORD, SECTIGO_CUSTOMER_URI
Optional:          SECTIGO_BASE_URL  (default: https://cert-manager.com)
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

AGENTS = [
    {"id": 18227, "name": "us-east-1"},
    {"id": 18247, "name": "us-west-2"},
]

PAGE_SIZE = 200


def _creds() -> dict:
    try:
        return {
            "login": os.environ["SECTIGO_LOGIN"],
            "password": os.environ["SECTIGO_PASSWORD"],
            "customerUri": os.environ["SECTIGO_CUSTOMER_URI"],
            "base_url": os.environ.get(
                "SECTIGO_BASE_URL", "https://cert-manager.com"
            ).rstrip("/"),
        }
    except KeyError as k:
        sys.exit(f"Missing env var: {k.args[0]}")


def api_get(url: str, creds: dict) -> Any:
    req = urllib.request.Request(url)
    req.add_header("login", creds["login"])
    req.add_header("password", creds["password"])
    req.add_header("customerUri", creds["customerUri"])
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode("utf-8", errors="replace")
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        sys.exit(f"HTTP {e.code} {url}: {body[:400]}")
    except urllib.error.URLError as e:
        sys.exit(f"Network error {url}: {e.reason}")


def list_agent_certs(agent_id: int, creds: dict) -> list[dict]:
    """Page through all certs on this agent. Returns list of {sslId, commonName}."""
    certs = []
    position = 0
    while True:
        params = urllib.parse.urlencode({
            "networkId": agent_id,
            "size": PAGE_SIZE,
            "position": position,
        })
        page = api_get(f"{creds['base_url']}/api/ssl/v2?{params}", creds)
        if not isinstance(page, list) or not page:
            break
        certs.extend(page)
        if len(page) < PAGE_SIZE:
            break
        position += PAGE_SIZE
    return certs


def get_cert_details(cert_id: int, creds: dict) -> dict:
    return api_get(f"{creds['base_url']}/api/ssl/v2/{cert_id}", creds)


def get_locations(cert_id: int, creds: dict) -> list[dict]:
    for url in [
        f"{creds['base_url']}/api/ssl/v2/{cert_id}/renewalInfo",
        f"{creds['base_url']}/api/agent/v1/ssl/{cert_id}/location",
        f"{creds['base_url']}/api/ssl/v2/{cert_id}/location",
    ]:
        try:
            data = api_get(url, creds)
            if isinstance(data, list) and data:
                return data
            if isinstance(data, dict):
                for key in ("locations", "items", "data", "servers"):
                    if isinstance(data.get(key), list) and data[key]:
                        return data[key]
        except SystemExit:
            continue
    return []


def fqdns_from_locations(locations: list[dict]) -> set[str]:
    fqdns = set()
    for loc in locations:
        details = loc.get("details", {})
        raw = details.get("server_name") or loc.get("name") or ""
        raw = raw.strip()
        if ":" in raw:
            raw = raw.rsplit(":", 1)[0]
        if not raw or raw.startswith("*") or "." not in raw:
            continue
        fqdns.add(raw)
    return fqdns


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="List all server nodes on Sectigo agents with their cert.",
    )
    p.add_argument("--output", default=None)
    p.add_argument(
        "--all-certs",
        action="store_true",
        help="Fetch full cert details (orderNumber) for every cert. Slower but complete.",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    creds = _creds()

    # server_fqdn → best row (prefer a row that has an order number)
    # Use dict so duplicate server+cert combos across agents collapse cleanly
    rows: dict[tuple[str, int], dict] = {}

    for agent in AGENTS:
        agent_id = agent["id"]
        agent_name = agent["name"]

        print(f"\nAgent {agent_id} ({agent_name}): fetching cert list...")
        cert_list = list_agent_certs(agent_id, creds)
        print(f"  {len(cert_list)} cert(s) found")

        for i, cert_stub in enumerate(cert_list, 1):
            cert_id = cert_stub.get("sslId") or cert_stub.get("id")
            cn = cert_stub.get("commonName", "")
            if not cert_id:
                continue

            print(f"  [{i}/{len(cert_list)}] cert {cert_id}  {cn}", end=" ", flush=True)

            locations = get_locations(cert_id, creds)
            fqdns = fqdns_from_locations(locations)

            if not fqdns:
                print("(no nodes)")
                continue

            # Get orderNumber — it's only in full cert details
            order_number = ""
            if args.all_certs or True:  # always fetch; ~100 certs is manageable
                details = get_cert_details(cert_id, creds)
                order_number = str(details.get("orderNumber") or details.get("backendCertId") or "")

            print(f"→ {len(fqdns)} node(s)")

            for fqdn in sorted(fqdns):
                key = (fqdn.lower(), cert_id)
                rows[key] = {
                    "server_fqdn": fqdn,
                    "cert_common_name": cn,
                    "order_number": order_number,
                    "cert_id": cert_id,
                    "agent_id": agent_id,
                    "agent_name": agent_name,
                }

    all_rows = sorted(rows.values(), key=lambda r: (r["server_fqdn"].lower(), r["cert_common_name"]))

    # Console summary: group by server so you can see if any server has multiple certs
    print(f"\n{'='*70}")
    print(f"  {len(all_rows)} total server/cert associations across {len({r['server_fqdn'] for r in all_rows})} unique servers")
    print(f"{'='*70}")

    # Flag servers with more than one cert (still have old + new)
    from collections import defaultdict
    by_server: dict[str, list[dict]] = defaultdict(list)
    for r in all_rows:
        by_server[r["server_fqdn"].lower()].append(r)

    multi = {s: entries for s, entries in by_server.items() if len(entries) > 1}
    if multi:
        print(f"\n  Servers with MULTIPLE certs bound ({len(multi)}) — likely still mid-migration:")
        for server, entries in sorted(multi.items()):
            print(f"\n    {server}")
            for e in entries:
                print(f"      order {e['order_number'] or e['cert_id']:>12}  {e['cert_common_name']}")

    # Write CSV
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = args.output or f"agent_nodes_{timestamp}.csv"
    fieldnames = ["server_fqdn", "cert_common_name", "order_number", "cert_id", "agent_id", "agent_name"]
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(all_rows)

    print(f"\nFull report: {out_path}")


if __name__ == "__main__":
    main()
