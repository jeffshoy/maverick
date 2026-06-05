#!/usr/bin/env python3
"""Remove servers from a Sectigo SCM Network Agent by ID or name filter.

Reads server IDs from a CSV (produced by list_servers.py) or accepts an
inline name filter to match against live agent data. Issues a DELETE per
server. Supports --dry-run to preview without making changes.

Usage:
  python remove_servers_from_agent.py --agent-id 18227 --csv servers_18227_inactive_search_*.csv
  python remove_servers_from_agent.py --agent-id 18227 --search smia --inactive --dry-run
  python remove_servers_from_agent.py --agent-id 18227 --search smia --inactive

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

DEFAULT_AGENT_ID = 18227
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


def _headers(creds: dict) -> dict:
    return {
        "login": creds["login"],
        "password": creds["password"],
        "customerUri": creds["customerUri"],
        "Accept": "application/json",
    }


def api_get(url: str, creds: dict) -> list | dict:
    req = urllib.request.Request(url)
    for k, v in _headers(creds).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode("utf-8", errors="replace")
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        sys.exit(f"HTTP {e.code} from {url}:\n  {body[:500]}")
    except urllib.error.URLError as e:
        sys.exit(f"Network error reaching {url}: {e.reason}")


def api_delete(url: str, creds: dict) -> tuple[bool, int, str]:
    """Issue DELETE. Returns (success, http_status, body)."""
    req = urllib.request.Request(url, method="DELETE")
    for k, v in _headers(creds).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode("utf-8", errors="replace")
            return True, r.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        return False, e.code, body[:300]
    except urllib.error.URLError as e:
        return False, 0, f"network error: {e.reason}"


def fetch_all_servers(agent_id: int, creds: dict) -> list[dict]:
    servers: list[dict] = []
    position = 0
    while True:
        params = urllib.parse.urlencode({"size": PAGE_SIZE, "position": position})
        url = f"{creds['base_url']}/api/agent/v1/network/{agent_id}/server?{params}"
        data = api_get(url, creds)
        page = data if isinstance(data, list) else []
        if not page:
            break
        servers.extend(page)
        if len(page) < PAGE_SIZE:
            break
        position += PAGE_SIZE
    return servers


def _is_inactive(s: dict) -> bool:
    if "active" in s:
        return s["active"] is False
    return str(s.get("status", "")).upper() in ("INACTIVE", "DISABLED")


def load_from_csv(path: str) -> list[dict]:
    """Return list of {id, name} dicts from a list_servers.py CSV."""
    try:
        with open(path, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
    except FileNotFoundError:
        sys.exit(f"CSV file not found: {path}")
    if not rows:
        sys.exit(f"CSV file is empty: {path}")
    if "id" not in rows[0]:
        sys.exit(f"CSV missing 'id' column. Expected a list_servers.py output file.")
    return [{"id": int(r["id"]), "name": r.get("name", "")} for r in rows]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Remove servers from a Sectigo SCM Network Agent.",
        epilog=(
            "Examples:\n"
            "  python remove_servers_from_agent.py --agent-id 18227 --csv servers_18227_inactive_search_*.csv\n"
            "  python remove_servers_from_agent.py --agent-id 18227 --search smia --inactive --dry-run\n"
            "  python remove_servers_from_agent.py --agent-id 18227 --search smia --inactive\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--agent-id", type=int, default=DEFAULT_AGENT_ID,
                   help=f"Network agent ID (default: {DEFAULT_AGENT_ID})")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--csv", metavar="FILE",
                     help="CSV file from list_servers.py (contains id + name columns).")
    src.add_argument("--search", metavar="NAME",
                     help="Case-insensitive name substring — fetches live agent data and filters.")
    p.add_argument("--inactive", action="store_true",
                   help="When used with --search, restrict to inactive servers only.")
    p.add_argument("--dry-run", action="store_true",
                   help="Print what would be deleted without calling the API.")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    creds = _creds()

    # --- Build the target list ---
    if args.csv:
        targets = load_from_csv(args.csv)
        print(f"Loaded {len(targets)} server(s) from {args.csv}")
    else:
        print(f"Fetching live server list from agent {args.agent_id}...")
        all_servers = fetch_all_servers(args.agent_id, creds)
        needle = args.search.lower()
        targets_raw = [s for s in all_servers if needle in str(s.get("name", "")).lower()]
        if args.inactive:
            targets_raw = [s for s in targets_raw if _is_inactive(s)]
        targets = [{"id": int(s["id"]), "name": s.get("name", "")} for s in targets_raw]
        print(f"Found {len(targets)} server(s) matching filter.")

    if not targets:
        print("No servers to remove.")
        sys.exit(0)

    # --- Preview ---
    print(f"\n{'[DRY-RUN] ' if args.dry_run else ''}Servers to remove from agent {args.agent_id}:")
    print(f"  {'ID':<10} {'NAME'}")
    print("  " + "-" * 60)
    for t in targets:
        print(f"  {t['id']:<10} {t['name']}")

    if args.dry_run:
        print(f"\n[dry-run] Would DELETE {len(targets)} server(s). Re-run without --dry-run to apply.")
        sys.exit(0)

    # --- Confirm ---
    print(f"\nAbout to permanently remove {len(targets)} server(s) from agent {args.agent_id}.")
    answer = input("Type 'yes' to confirm: ").strip().lower()
    if answer != "yes":
        print("Aborted.")
        sys.exit(0)

    # --- Execute ---
    print()
    failures = 0
    for t in targets:
        url = f"{creds['base_url']}/api/agent/v1/network/{args.agent_id}/server/{t['id']}"
        ok, status, body = api_delete(url, creds)
        label = f"{t['id']:<10} {t['name']}"
        if ok:
            print(f"[OK  ] {label}  (HTTP {status})")
        else:
            print(f"[FAIL] {label}  (HTTP {status}: {body})")
            failures += 1

    print(f"\nDone. {len(targets) - failures} removed, {failures} failed.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
