#!/usr/bin/env python3
"""Verify AWS profiles and local domain DNS for all accounts in the CSV.

For every row where In Use=yes, already_created!=yes, servers_added!=yes:
  1. Check the aws_profile exists in ~/.aws/config
  2. Call sts:GetCallerIdentity to confirm credentials are valid
  3. Resolve the local_domain via DNS to confirm it's reachable

Usage:
  python verify_accounts.py
  python verify_accounts.py --skip-dns   # skip DNS checks (faster)
"""

from __future__ import annotations

import argparse
import csv
import socket
import sys
from pathlib import Path

import boto3
from botocore.exceptions import ClientError, NoCredentialsError, ProfileNotFound

SCRIPT_DIR = Path(__file__).parent
CSV_PATH = SCRIPT_DIR / "ASPGOV_SSLCertRenewal_2026-2027.csv"


def check_profile(profile: str, domain: str, skip_dns: bool) -> dict:
    result = {
        "profile": profile,
        "domain": domain,
        "profile_exists": False,
        "auth_ok": False,
        "account_id": "",
        "dns_ok": None,
        "dns_resolved": "",
        "error": "",
    }

    # --- AWS profile + credentials ---
    try:
        session = boto3.Session(profile_name=profile)
        result["profile_exists"] = True
    except ProfileNotFound:
        result["error"] = "profile not found in ~/.aws/config"
        return result

    try:
        identity = session.client("sts").get_caller_identity()
        result["auth_ok"] = True
        result["account_id"] = identity["Account"]
    except NoCredentialsError:
        result["error"] = "no credentials — run: aws sso login --profile " + profile
    except ClientError as e:
        result["error"] = str(e.response["Error"]["Message"])

    if not result["auth_ok"]:
        return result

    # --- DNS resolution of local domain ---
    if not skip_dns and domain:
        try:
            addr = socket.gethostbyname(domain)
            result["dns_ok"] = True
            result["dns_resolved"] = addr
        except socket.gaierror as e:
            result["dns_ok"] = False
            result["dns_resolved"] = str(e)

    return result


def load_rows(csv_path: Path) -> list[dict]:
    with open(csv_path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))

    to_check = []
    for row in rows:
        if row.get("In Use?", "").strip().lower() != "yes":
            continue
        if row.get("split cert already created?", "").strip().lower() == "yes":
            continue
        if row.get("servers_added", "").strip().lower() == "yes":
            continue
        profile = row.get("aws_profile", "").strip()
        domain = row.get("local_domain", "").strip()
        if not profile:
            continue
        to_check.append({"profile": profile, "domain": domain, "san": row.get("SAN", "")})

    return to_check


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Verify AWS profiles and DNS for all CSV accounts.")
    p.add_argument("--skip-dns", action="store_true", help="Skip DNS resolution checks.")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    rows = load_rows(CSV_PATH)

    print(f"Checking {len(rows)} account(s)...\n")

    ok = []
    warn = []       # auth works, DNS fails
    failed = []     # profile missing or auth broken

    for row in rows:
        print(f"  {row['profile']:<30} {row['domain']}", end=" ... ", flush=True)
        result = check_profile(row["profile"], row["domain"], args.skip_dns)
        result["san"] = row["san"]

        if not result["profile_exists"] or not result["auth_ok"]:
            print("FAIL")
            failed.append(result)
        elif result["dns_ok"] is False:
            print("WARN (DNS)")
            warn.append(result)
        else:
            status = "OK"
            if result["dns_ok"] is True:
                status += f"  dns→{result['dns_resolved']}"
            elif args.skip_dns:
                status += "  (dns skipped)"
            print(status)
            ok.append(result)

    # Summary
    print()
    print("=" * 70)
    print(f"OK    : {len(ok)}")
    print(f"WARN  : {len(warn)}  (auth OK, DNS not resolving — may be normal if not on VPN)")
    print(f"FAIL  : {len(failed)}")

    if warn:
        print("\nDNS warnings (auth OK but domain did not resolve):")
        for r in warn:
            print(f"  {r['profile']:<30} {r['domain']}")
            print(f"    DNS error: {r['dns_resolved']}")

    if failed:
        print("\nFailures (need attention before batch run):")
        for r in failed:
            print(f"  {r['profile']:<30} {r['san']}")
            print(f"    Error: {r['error']}")

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
