#!/usr/bin/env python3
"""List servers on a Sectigo SCM Network Agent.

Paginates through all servers on the given agent. By default shows all servers
with their active status. Use --inactive to filter to inactive servers only, or
--search to find a specific server by name substring.

Usage:
  python list_servers.py
  python list_servers.py --inactive
  python list_servers.py --search cld-splsap102
  python list_servers.py --search splsap --agent-id 18227
  python list_servers.py --inactive --output inactive.csv

Required env vars: SECTIGO_LOGIN, SECTIGO_PASSWORD
Optional:          SECTIGO_CUSTOMER_URI  (default: centralsquare)
                   SECTIGO_BASE_URL      (default: https://cert-manager.com)
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

DEFAULT_AGENT_ID = 18227
PAGE_SIZE = 200


def _creds() -> dict:
    try:
        return {
            "login": os.environ["SECTIGO_LOGIN"],
            "password": os.environ["SECTIGO_PASSWORD"],
            "customerUri": os.environ.get("SECTIGO_CUSTOMER_URI", "centralsquare"),
            "base_url": os.environ.get(
                "SECTIGO_BASE_URL", "https://cert-manager.com"
            ).rstrip("/"),
        }
    except KeyError as k:
        sys.exit(f"Missing env var: {k.args[0]}")


def api_get(url: str, creds: dict) -> dict | list:
    req = urllib.request.Request(url)
    req.add_header("login", creds["login"])
    req.add_header("password", creds["password"])
    req.add_header("customerUri", creds["customerUri"])
    req.add_header("Accept", "application/json")
    print(f"  GET {url}", flush=True)
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode("utf-8", errors="replace")
            print(f"  HTTP {r.status}  ({len(body)} bytes)", flush=True)
            if not body.strip():
                return {}
            return json.loads(body)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        sys.exit(f"HTTP {e.code} from {url}:\n  {body[:500]}")
    except urllib.error.URLError as e:
        sys.exit(f"Network error reaching {url}: {e.reason}")


def fetch_all_servers(agent_id: int, creds: dict) -> list[dict]:
    """Page through all servers on this agent and return the full list."""
    servers: list[dict] = []
    position = 0
    while True:
        params = urllib.parse.urlencode({"size": PAGE_SIZE, "position": position})
        url = f"{creds['base_url']}/api/agent/v1/network/{agent_id}/server?{params}"
        data = api_get(url, creds)

        # Debug: show raw structure on first page
        if position == 0:
            print(f"\n  Response type: {type(data).__name__}")
            if isinstance(data, dict):
                print(f"  Top-level keys: {list(data.keys())}")
                for key in ("value", "servers", "items", "data"):
                    if isinstance(data.get(key), list):
                        print(f"  List is under key '{key}', length: {len(data[key])}")
                        if data[key]:
                            print(f"  First item keys: {list(data[key][0].keys())}")
                        break
            elif isinstance(data, list):
                print(f"  Bare list, length: {len(data)}")
                if data:
                    print(f"  First item keys: {list(data[0].keys())}")

        page: list[dict] = []
        if isinstance(data, list):
            page = data
        elif isinstance(data, dict):
            for key in ("value", "servers", "items", "data"):
                if isinstance(data.get(key), list):
                    page = data[key]
                    break

        if not page:
            print(f"  No more results at position {position}.")
            break

        servers.extend(page)
        print(f"  Page at position {position}: {len(page)} server(s) (total so far: {len(servers)})")

        if len(page) < PAGE_SIZE:
            break
        position += PAGE_SIZE

    return servers


def _is_inactive(s: dict) -> bool:
    if "active" in s:
        return s["active"] is False
    if "status" in s:
        return str(s.get("status", "")).upper() in ("INACTIVE", "DISABLED")
    return False


def _active_str(s: dict) -> str:
    if "active" in s:
        return str(s["active"]).lower()
    return str(s.get("status", "?")).lower()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="List servers on a Sectigo SCM Network Agent.",
        epilog=(
            "Examples:\n"
            "  python list_servers.py                          # all servers\n"
            "  python list_servers.py --inactive               # inactive only\n"
            "  python list_servers.py --search cld-splsap102   # find by name\n"
            "  python list_servers.py --search splsap --inactive  # inactive matching name\n"
            "  python list_servers.py --agent-id 18247         # west agent\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--agent-id", type=int, default=DEFAULT_AGENT_ID,
                   help=f"Network agent ID (default: {DEFAULT_AGENT_ID} = us-east-1; 18247 = us-west-2)")
    p.add_argument("--inactive", action="store_true",
                   help="Show only inactive servers.")
    p.add_argument("--search", default=None, metavar="NAME",
                   help="Case-insensitive substring to match against server name.")
    p.add_argument("--output", default=None,
                   help="CSV output path (auto-named if omitted).")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    creds = _creds()

    print(f"\nQuerying agent {args.agent_id} at {creds['base_url']}...")
    print(f"Login: {creds['login']}  customerUri: {creds['customerUri']}\n")

    all_servers = fetch_all_servers(args.agent_id, creds)
    print(f"\nTotal servers retrieved: {len(all_servers)}")

    if not all_servers:
        print("No servers returned — check agent ID and credentials.")
        sys.exit(1)

    all_keys: set[str] = set()
    for s in all_servers:
        all_keys.update(s.keys())
    print(f"Fields present in server objects: {sorted(all_keys)}")

    # Apply filters
    results = all_servers

    if args.search:
        needle = args.search.lower()
        results = [s for s in results if needle in str(s.get("name", "")).lower()]
        print(f"\nSearch '{args.search}': {len(results)} match(es)")

    if args.inactive:
        results = [s for s in results if _is_inactive(s)]
        print(f"Inactive filter: {len(results)} server(s)")

    if not results:
        print("\nNo servers matched the given filters.")
        sys.exit(0)

    # Determine label and default output filename
    if args.inactive and args.search:
        label = f"inactive servers matching '{args.search}'"
        default_out = f"servers_{args.agent_id}_inactive_search_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    elif args.inactive:
        label = "inactive servers"
        default_out = f"servers_{args.agent_id}_inactive_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    elif args.search:
        label = f"servers matching '{args.search}'"
        default_out = f"servers_{args.agent_id}_search_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    else:
        label = "all servers"
        default_out = f"servers_{args.agent_id}_all_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"

    print(f"\n{len(results)} {label}:\n")
    print(f"{'ID':<10} {'ACTIVE':<8} {'NAME'}")
    print("-" * 70)
    for s in sorted(results, key=lambda x: str(x.get("name", "")).lower()):
        print(f"{s.get('id', ''):<10} {_active_str(s):<8} {s.get('name', '')}")

    out_path = args.output or default_out
    fieldnames = sorted(all_keys)
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    print(f"\nCSV written: {out_path}")


if __name__ == "__main__":
    main()
