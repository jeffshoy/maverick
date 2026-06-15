#!/usr/bin/env python3
"""Report which servers still have the old *.aspgov.com cert discovered by the agent.

The Sectigo network agent scans IIS bindings and reports cert locations regardless
of whether Sectigo installed the cert. So a server appearing in cert 14546938's
location list means the agent FOUND that cert bound in IIS on that server.

For every in-use account in the CSV with a client-specific SAN, Sectigo is queried
to find the split cert (whether or not the CSV column "split cert already created?"
is marked). This catches all ~50 split certs, not just the 6 marked in the CSV.

Logic:
  - Fetch all server FQDNs from old cert 14546938  (what the agent sees NOW)
  - For every in-use client SAN, search Sectigo for that cert and fetch its locations
  - Classify each server:

    MIGRATED        server appears in the split cert's location list
                    (agent found the new cert on that server)
    STILL_OLD_CERT  server is NOT in the split cert location list
                    (old cert still bound — needs migration)
    NO_SPLIT_CERT   no split cert found in Sectigo yet for this account
    NO_CSV_MATCH    FQDN doesn't match any local_domain in the CSV

Usage:
  python audit_split_certs.py
  python audit_split_certs.py --old-cert-id 14546938   (default)
  python audit_split_certs.py --debug

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
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).parent
CSV_PATH = SCRIPT_DIR / "ASPGOV_SSLCertRenewal_2026-2027.csv"
OLD_CERT_ID_DEFAULT = 14546938
NEW_SHARED_ASPGOV_CERT_ID = 19506604


# ---------------------------------------------------------------------------
# Sectigo API helpers
# ---------------------------------------------------------------------------

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


def search_cert_id(cn: str, creds: dict) -> int | None:
    params = urllib.parse.urlencode({"commonName": cn, "size": 25})
    results = api_get(f"{creds['base_url']}/api/ssl/v2?{params}", creds)
    if not isinstance(results, list):
        return None
    # Prefer the most recently issued cert (highest sslId) with status Issued.
    # Fall back to highest sslId regardless of status if none are Issued.
    matches = [r for r in results if r.get("commonName", "").lower() == cn.lower()]
    issued = [r for r in matches if str(r.get("status", "")).lower() == "issued"]
    candidates = issued if issued else matches
    if not candidates:
        return None
    return max(candidates, key=lambda r: r["sslId"])["sslId"]


def get_locations(cert_id: int, creds: dict) -> list[dict]:
    for url in [
        f"{creds['base_url']}/api/ssl/v2/{cert_id}/location",
        f"{creds['base_url']}/api/agent/v1/ssl/{cert_id}/location",
        f"{creds['base_url']}/api/ssl/v2/{cert_id}/renewalInfo",
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
    """Return unique server FQDNs (no port, no garbage entries) from a location list."""
    fqdns = set()
    for loc in locations:
        details = loc.get("details", {})
        # details.server_name is the clean FQDN; loc.name may include :port
        raw = details.get("server_name") or loc.get("name") or ""
        raw = raw.strip()
        if ":" in raw:
            raw = raw.rsplit(":", 1)[0]
        if not raw or raw.startswith("*") or "." not in raw:
            continue
        fqdns.add(raw.lower())
    return fqdns


# ---------------------------------------------------------------------------
# CSV helpers
# ---------------------------------------------------------------------------

def load_csv(path: Path) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def build_domain_index(rows: list[dict]) -> dict[str, dict]:
    return {
        r["local_domain"].strip().lower(): r
        for r in rows
        if r.get("local_domain", "").strip()
    }


def match_fqdn_to_domain(fqdn: str, domain_index: dict[str, dict]) -> str | None:
    for domain in domain_index:
        if fqdn.endswith("." + domain) or fqdn == domain:
            return domain
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="List servers still on the old *.aspgov.com cert.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--old-cert-id", type=int, default=OLD_CERT_ID_DEFAULT)
    p.add_argument("--output", default=None)
    p.add_argument("--debug", action="store_true")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    creds = _creds()

    # ── 1. Old cert: get every server the agent currently sees it on ──────────
    print(f"Fetching locations for old cert {args.old_cert_id}...")
    old_locations = get_locations(args.old_cert_id, creds)
    old_fqdns = fqdns_from_locations(old_locations)
    print(f"  {len(old_locations)} records -> {len(old_fqdns)} unique server FQDNs\n")

    if not old_fqdns:
        print("No server FQDNs found. Re-run with --debug.")
        sys.exit(0)

    if args.debug:
        print("Sample location records from old cert:")
        for loc in old_locations[:3]:
            print(f"  {json.dumps(loc)}")
        print()

    # ── 2. Load CSV, build domain index ──────────────────────────────────────
    rows = load_csv(CSV_PATH)
    domain_index = build_domain_index(rows)

    # ── 3. Split certs: get every server the agent sees the NEW cert on ───────
    # split_fqdns[local_domain] = set of FQDNs where that split cert was found
    split_fqdns: dict[str, set[str]] = {}
    split_cert_ids: dict[str, int] = {}
    split_cert_sans: dict[str, str] = {}

    # ── 3a. New shared *.aspgov.com cert: fetch its locations once upfront ───────
    print(f"Fetching locations for new shared *.aspgov.com cert {NEW_SHARED_ASPGOV_CERT_ID}...")
    shared_locs = get_locations(NEW_SHARED_ASPGOV_CERT_ID, creds)
    shared_aspgov_fqdns = fqdns_from_locations(shared_locs)
    print(f"  agent sees it on {len(shared_aspgov_fqdns)} server(s)\n")

    # Use every row that has a client-specific SAN (not the bare *.aspgov.com rows).
    # Do NOT filter by "In Use?" — that column is unreliable and causes split certs to be
    # missed for accounts marked "no" that still have servers on the old cert (e.g. calco).
    # We query Sectigo directly to determine whether a cert exists.
    split_rows = [
        r for r in rows
        if r.get("local_domain", "").strip()
        and r.get("SAN", "").strip()
        and r["SAN"].strip().lower() not in ("*.aspgov.com", "aspgov.com")
    ]

    if split_rows:
        print(f"Fetching locations for {len(split_rows)} split cert(s)...")
        for row in split_rows:
            domain = row["local_domain"].strip().lower()
            san = row["SAN"].strip()
            split_cert_sans[domain] = san

            cert_id = search_cert_id(san, creds)
            if cert_id is None:
                print(f"  {san:<45} no cert in Sectigo yet")
                split_fqdns[domain] = set()
                continue

            split_cert_ids[domain] = cert_id
            locs = get_locations(cert_id, creds)
            found = fqdns_from_locations(locs)
            split_fqdns[domain] = found
            print(f"  {san:<45} cert {cert_id}  agent sees it on {len(found)} server(s)")

            if args.debug:
                for f in sorted(found):
                    print(f"    {f}")
        print()

    # ── 4. Classify every server on the old cert ──────────────────────────────
    results: list[dict] = []

    for fqdn in sorted(old_fqdns):
        matched_domain = match_fqdn_to_domain(fqdn, domain_index)

        if matched_domain is None:
            status = "NO_CSV_MATCH"
            san = ""
            split_cert_id = ""
        else:
            row = domain_index[matched_domain]
            san = row.get("SAN", "").strip()
            domain_in_split = matched_domain in split_fqdns

            if not domain_in_split:
                # *.aspgov.com row — check the new shared cert
                if fqdn in shared_aspgov_fqdns:
                    status = "MIGRATED"
                    split_cert_id = str(NEW_SHARED_ASPGOV_CERT_ID)
                else:
                    status = "STILL_OLD_CERT"
                    split_cert_id = ""
            elif not split_cert_ids.get(matched_domain):
                # Queried Sectigo, tenant split cert doesn't exist yet
                if fqdn in shared_aspgov_fqdns:
                    status = "MIGRATED"
                    split_cert_id = str(NEW_SHARED_ASPGOV_CERT_ID)
                else:
                    status = "NO_SPLIT_CERT"
                    split_cert_id = ""
            elif fqdn in split_fqdns[matched_domain]:
                status = "MIGRATED"
                split_cert_id = str(split_cert_ids[matched_domain])
            else:
                status = "STILL_OLD_CERT"
                split_cert_id = str(split_cert_ids[matched_domain])

        results.append({
            "old_cert_id": args.old_cert_id,
            "server_fqdn": fqdn,
            "local_domain": matched_domain or "",
            "split_cert_san": san,
            "split_cert_id": split_cert_id,
            "status": status,
        })

    # ── 5. Console report ─────────────────────────────────────────────────────
    sections = [
        ("STILL ON OLD CERT — action required", "STILL_OLD_CERT"),
        ("MIGRATED to split cert", "MIGRATED"),
        ("NO SPLIT CERT YET (informational)", "NO_SPLIT_CERT"),
        ("NO CSV MATCH (check local_domain)", "NO_CSV_MATCH"),
    ]

    status_counts: dict[str, int] = defaultdict(int)
    for r in results:
        status_counts[r["status"]] += 1

    for section_label, status_key in sections:
        section_rows = [r for r in results if r["status"] == status_key]
        if not section_rows:
            continue

        print(f"{'='*70}")
        print(f"  {section_label}  ({len(section_rows)} server(s))")
        print(f"{'='*70}")

        # Group by account SAN for readability
        by_san: dict[str, list[str]] = defaultdict(list)
        for r in section_rows:
            key = r["split_cert_san"] or r["local_domain"] or "unmatched"
            by_san[key].append(r["server_fqdn"])

        for san, fqdns in sorted(by_san.items()):
            print(f"\n  [{san}]")
            for f in sorted(fqdns):
                print(f"    {f}")
        print()

    print(f"{'='*70}")
    print("TOTALS")
    print(f"{'='*70}")
    for status, count in sorted(status_counts.items()):
        print(f"  {status:<25} {count}")
    print(f"  {'Total unique servers':<25} {len(old_fqdns)}")

    # ── 6. Write CSV ──────────────────────────────────────────────────────────
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = args.output or f"audit_split_certs_{timestamp}.csv"
    fieldnames = [
        "old_cert_id", "server_fqdn", "local_domain",
        "split_cert_san", "split_cert_id", "status",
    ]
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(
            sorted(results, key=lambda r: (r["status"], r["server_fqdn"]))
        )

    print(f"\nFull report: {out_path}")
    sys.exit(1 if status_counts.get("STILL_OLD_CERT", 0) > 0 else 0)


if __name__ == "__main__":
    main()
