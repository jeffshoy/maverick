#!/usr/bin/env python3
"""Drive build_server_list.py + add_servers_to_agent.py across all accounts.

Reads ASPGOV_SSLCertRenewal_2026-2027.csv and processes every row where:
  - In Use?  = yes
  - split cert already created? != yes
  - servers_added != yes
  - aws_profile and local_domain are populated

For each qualifying account it:
  1. Runs build_server_list.py to discover EC2 instances and write per-region JSON
  2. For each output file, runs add_servers_to_agent.py against the correct agent
  3. Deletes the JSON files immediately after import
  4. Prompts before each account (unless --auto-confirm is set)

Agent IDs (fixed, region-based):
  us-east-1  → 18227
  us-west-2  → 18247

All other regions discovered in an account also use the east agent as a
safe default — confirm with Sectigo if an account has west instances.

The service account password is read from the environment variable named
by --password-env. Set it before running:
  $env:SECTIGO_SVC_PASSWORD = "from-your-password-manager"

Usage:
  # Dry-run everything — no JSON written, no Sectigo calls:
  python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD --dry-run

  # Live run with per-account confirmation prompts:
  python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD

  # Skip prompts (careful — runs all qualifying accounts unattended):
  python batch_add_servers.py --password-env SECTIGO_SVC_PASSWORD --auto-confirm
"""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
BUILD_SCRIPT = SCRIPT_DIR / "build_server_list.py"
ADD_SCRIPT = SCRIPT_DIR / "add_servers_to_agent.py"
CSV_PATH = SCRIPT_DIR / "ASPGOV_SSLCertRenewal_2026-2027.csv"

AGENT_IDS: dict[str, int] = {
    "us-east-1": 18227,
    "us-west-2": 18247,
}
DEFAULT_AGENT_ID = 18227  # east agent as safe default for unlisted regions

USERNAME = "CLOUD\\sectigo_svc"


def load_accounts(csv_path: Path) -> list[dict[str, str]]:
    """Return rows that need processing from the CSV."""
    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    to_process = []
    skipped = []
    for row in rows:
        san = row.get("SAN", "").strip()
        in_use = row.get("In Use?", "").strip().lower()
        already_created = row.get("split cert already created?", "").strip().lower()
        servers_added = row.get("servers_added", "").strip().lower()
        profile = row.get("aws_profile", "").strip()
        domain = row.get("local_domain", "").strip()

        if in_use != "yes":
            skipped.append(f"  SKIP (not in use):       {san}")
            continue
        if already_created == "yes":
            skipped.append(f"  SKIP (cert exists):      {san}")
            continue
        if servers_added == "yes":
            skipped.append(f"  SKIP (servers added):    {san}")
            continue
        if not profile or not domain:
            skipped.append(f"  SKIP (no profile/domain): {san}")
            continue

        to_process.append(row)

    print(f"Accounts to process : {len(to_process)}")
    print(f"Skipped             : {len(skipped)}")
    if skipped:
        for s in skipped:
            print(s)
    print()
    return to_process


def run_build(cmd: list[str]) -> int:
    """Run build_server_list.py, streaming output. Returns exit code."""
    print(f"  $ {' '.join(cmd)}")
    result = subprocess.run(cmd, text=True)
    return result.returncode


def run_add(cmd: list[str]) -> tuple[int, list[dict[str, str]]]:
    """Run add_servers_to_agent.py, capture output, parse per-server results.

    Returns (exit_code, list of {fqdn, status, message} dicts).
    Output lines look like:
      [OK  ] servername.domain: created (id=42)
      [FAIL] servername.domain: HTTP 409: ...
    """
    print(f"  $ {' '.join(cmd)}")
    result = subprocess.run(cmd, text=True, capture_output=False,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = result.stdout or ""
    print(output, end="")

    records: list[dict[str, str]] = []
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("[OK  ]") or line.startswith("[FAIL]"):
            status = "OK" if line.startswith("[OK") else "FAIL"
            rest = line[6:].strip()  # strip "[OK  ] " or "[FAIL] "
            fqdn, _, message = rest.partition(": ")
            records.append({"fqdn": fqdn.strip(), "status": status, "message": message.strip()})

    return result.returncode, records


def process_account(
    row: dict[str, str],
    password_env: str,
    dry_run: bool,
) -> tuple[bool, list[dict[str, str]]]:
    """Build JSON and import servers for one account.

    Returns (success, list of per-server result dicts).
    """
    san = row["SAN"]
    profile = row["aws_profile"].strip()
    domain = row["local_domain"].strip()
    client_id = row.get("client_id", "").strip()
    name_filters = row.get("name_filters", "").strip()

    print("=" * 70)
    print(f"Account : {profile}")
    print(f"Domain  : {domain}")
    print(f"SAN     : {san}")
    if name_filters:
        print(f"Filters : {name_filters}")
    print()

    output_prefix = str(SCRIPT_DIR / f"servers_{client_id or profile}")

    # Step 1: discover and build JSON files split by region
    build_cmd = [
        sys.executable, str(BUILD_SCRIPT),
        "--profile", profile,
        "--domain", domain,
        "--username", USERNAME,
        "--password-env", password_env,
        "--output-prefix", output_prefix,
    ]
    if name_filters:
        build_cmd += ["--name-filters", name_filters]
    if dry_run:
        build_cmd.append("--dry-run")

    print(f"  $ {' '.join(build_cmd)}")
    if dry_run:
        subprocess.run(build_cmd, text=True)
        return True, []

    rc = run_build(build_cmd)
    if rc != 0:
        print(f"  ERROR: build_server_list.py exited {rc} — skipping import for {profile}")
        return False, []

    # Step 2: find the files that were written and import each one
    import glob as glob_mod
    output_files = sorted(glob_mod.glob(f"{output_prefix}_*.json"))
    if not output_files:
        print(f"  No output files found — no matching instances in {profile}")
        return True, []

    all_ok = True
    all_records: list[dict[str, str]] = []

    for json_file in output_files:
        stem = Path(json_file).stem          # servers_ANCO_us-east-1
        region = stem.rsplit("_", 1)[-1]     # us-east-1
        agent_id = AGENT_IDS.get(region, DEFAULT_AGENT_ID)

        print()
        print(f"  Importing {json_file} → agent {agent_id} (region: {region})")

        add_cmd = [
            sys.executable, str(ADD_SCRIPT),
            "--agent-id", str(agent_id),
            json_file,
        ]
        rc, records = run_add(add_cmd)

        for r in records:
            r["account"] = profile
            r["san"] = san
            r["region"] = region
            r["agent_id"] = str(agent_id)
        all_records.extend(records)

        # Always delete — file contains plaintext credentials.
        try:
            os.remove(json_file)
            print(f"  Deleted {json_file}")
        except OSError as e:
            print(f"  WARNING: could not delete {json_file}: {e}")

        if rc != 0:
            print(f"  ERROR: add_servers_to_agent.py exited {rc} for {json_file}")
            all_ok = False

    return all_ok, all_records


def write_report(all_records: list[dict[str, str]], timestamp: str) -> Path:
    """Write a timestamped CSV report of all servers added."""
    report_path = SCRIPT_DIR / f"sectigo_servers_added_{timestamp}.csv"
    fieldnames = ["account", "san", "fqdn", "region", "agent_id", "status", "message"]
    with open(report_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(all_records)
    return report_path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Batch-import EC2 servers into Sectigo across all accounts in the CSV.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--password-env",
        required=True,
        metavar="VAR_NAME",
        help="Environment variable holding the Sectigo service account password.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Discover instances and print what would be imported. "
            "No JSON files written, no Sectigo API calls."
        ),
    )

    p.add_argument(
        "--profile",
        default=None,
        metavar="AWS_PROFILE",
        help="Process only this one profile (useful for testing a single account).",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()

    if not args.dry_run:
        password = os.environ.get(args.password_env, "")
        if not password:
            sys.exit(
                f"Environment variable '{args.password_env}' is not set or empty. "
                f"Set it before running:\n"
                f"  $env:{args.password_env} = 'your-password'"
            )

    accounts = load_accounts(CSV_PATH)

    if args.profile:
        accounts = [a for a in accounts if a["aws_profile"].strip() == args.profile]
        if not accounts:
            sys.exit(f"No processable row found for profile '{args.profile}' in CSV.")

    if not accounts:
        print("Nothing to process.")
        return

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    results: dict[str, bool] = {}
    all_records: list[dict[str, str]] = []

    for row in accounts:
        ok, records = process_account(row, args.password_env, args.dry_run)
        results[row["aws_profile"].strip()] = ok
        all_records.extend(records)

    print()
    print("=" * 70)
    print("Summary:")
    for profile, ok in results.items():
        status = "OK  " if ok else "FAIL"
        print(f"  [{status}] {profile}")

    if not args.dry_run and all_records:
        report_path = write_report(all_records, timestamp)
        ok_count = sum(1 for r in all_records if r["status"] == "OK")
        fail_count = sum(1 for r in all_records if r["status"] == "FAIL")
        print()
        print(f"Report  : {report_path}")
        print(f"Servers : {ok_count} added, {fail_count} failed")

    failures = sum(1 for ok in results.values() if not ok)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
