#!/usr/bin/env python3
"""Verify local AD domain names by SSM-ing into one EC2 instance per account.

For every qualifying row in the CSV (in_use=yes, not already done), finds the
first matching EC2 instance, runs a PowerShell domain query via SSM Run Command,
and compares the result to the local_domain value in the CSV.

This confirms the domain names are correct before any Sectigo import is attempted.

Usage:
  python verify_domains.py
  python verify_domains.py --profile PALegacyFinEntBRENT   # single account
"""

from __future__ import annotations

import argparse
import csv
import sys
import time
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import ClientError, NoCredentialsError, ProfileNotFound

SCRIPT_DIR = Path(__file__).parent
CSV_PATH = SCRIPT_DIR / "ASPGOV_SSLCertRenewal_2026-2027.csv"

REGIONS = ["us-east-1", "us-east-2", "us-west-1", "us-west-2"]

SSM_TIMEOUT = 30  # seconds to wait for SSM command to complete
SSM_POLL_INTERVAL = 3

# PowerShell command to retrieve the AD domain the machine is joined to
PS_GET_DOMAIN = "(Get-WmiObject Win32_ComputerSystem).Domain"


def find_all_instances(session: boto3.Session, name_filters: list[str]) -> list[dict[str, Any]]:
    """Return all running EC2 instances matching name filters across all regions."""
    found = []
    for region in REGIONS:
        ec2 = session.client("ec2", region_name=region)
        paginator = ec2.get_paginator("describe_instances")
        pages = paginator.paginate(
            Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
        )
        for page in pages:
            for reservation in page["Reservations"]:
                for inst in reservation["Instances"]:
                    name_tag = next(
                        (t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"),
                        "",
                    )
                    if any(f.lower() in name_tag.lower() for f in name_filters):
                        found.append({
                            "instance_id": inst["InstanceId"],
                            "name_tag": name_tag,
                            "region": region,
                        })
    return found


def check_ssm_managed(session: boto3.Session, region: str, instance_id: str) -> bool:
    """Return True if the instance is online in SSM."""
    ssm = session.client("ssm", region_name=region)
    try:
        resp = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
        )
        info = resp.get("InstanceInformationList", [])
        return bool(info) and info[0].get("PingStatus") == "Online"
    except ClientError:
        return False


def run_ssm_command(session: boto3.Session, region: str, instance_id: str) -> str:
    """Run PS_GET_DOMAIN via SSM and return the stdout output, or an error string."""
    ssm = session.client("ssm", region_name=region)

    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunPowerShellScript",
            Parameters={"commands": [PS_GET_DOMAIN]},
            TimeoutSeconds=SSM_TIMEOUT,
        )
    except ClientError as e:
        return f"SSM send error: {e.response['Error']['Message']}"

    command_id = resp["Command"]["CommandId"]

    # Poll until the command finishes
    deadline = time.time() + SSM_TIMEOUT
    while time.time() < deadline:
        time.sleep(SSM_POLL_INTERVAL)
        try:
            inv = ssm.get_command_invocation(
                CommandId=command_id,
                InstanceId=instance_id,
            )
        except ClientError as e:
            return f"SSM poll error: {e.response['Error']['Message']}"

        status = inv["Status"]
        if status in ("Success", "Failed", "Cancelled", "TimedOut"):
            if status == "Success":
                return inv.get("StandardOutputContent", "").strip()
            return f"SSM command {status}: {inv.get('StandardErrorContent', '').strip()}"

    return "SSM timed out waiting for command result"


def load_rows(csv_path: Path, filter_profile: str | None) -> list[dict]:
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
        if not profile or not domain:
            continue
        if filter_profile and profile != filter_profile:
            continue
        to_check.append(row)

    return to_check


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Verify AD domain names via SSM before Sectigo import.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--profile",
        default=None,
        metavar="AWS_PROFILE",
        help="Check only this profile (omit to check all qualifying accounts).",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    rows = load_rows(CSV_PATH, args.profile)

    if not rows:
        print("No qualifying rows found.")
        sys.exit(0)

    print(f"Verifying {len(rows)} account(s) via SSM...\n")

    match = []
    mismatch = []
    no_ssm = []
    auth_fail = []

    for row in rows:
        profile = row["aws_profile"].strip()
        expected_domain = row["local_domain"].strip().lower()
        san = row.get("SAN", "")

        print(f"  {profile:<35} expected: {expected_domain}", end=" ... ", flush=True)

        try:
            session = boto3.Session(profile_name=profile)
        except ProfileNotFound:
            print("FAIL (profile not found)")
            auth_fail.append({"profile": profile, "san": san, "error": "profile not found"})
            continue

        try:
            session.client("sts").get_caller_identity()
        except (NoCredentialsError, ClientError) as e:
            msg = str(e)
            print(f"FAIL (auth: {msg[:60]})")
            auth_fail.append({"profile": profile, "san": san, "error": msg})
            continue

        name_filters = [f.strip() for f in row.get("name_filters", "").split(",") if f.strip()]
        instances = find_all_instances(session, name_filters)
        if not instances:
            print("SKIP (no matching instances found)")
            no_ssm.append({"profile": profile, "san": san, "error": "no matching instances"})
            continue

        # Walk instances until one is reachable via SSM.
        inst = None
        for candidate in instances:
            if check_ssm_managed(session, candidate["region"], candidate["instance_id"]):
                inst = candidate
                break
            print(f"\n    SSM not online: {candidate['instance_id']} ({candidate['name_tag']}) — trying next ...", end="", flush=True)

        if inst is None:
            print(f"\n    SKIP (SSM not online for any of {len(instances)} instance(s))")
            no_ssm.append({
                "profile": profile,
                "san": san,
                "error": f"SSM not online for any of {len(instances)} matching instance(s)",
            })
            continue

        actual_domain = run_ssm_command(session, inst["region"], inst["instance_id"])

        if actual_domain.lower() == expected_domain:
            print(f"OK  (actual: {actual_domain}  instance: {inst['name_tag']})")
            match.append({"profile": profile, "domain": actual_domain})
        elif actual_domain.lower().startswith("ssm") or actual_domain.lower().startswith("error"):
            print(f"WARN ({actual_domain})")
            no_ssm.append({"profile": profile, "san": san, "error": actual_domain})
        else:
            print(f"MISMATCH  actual: {actual_domain}  instance: {inst['name_tag']}")
            mismatch.append({
                "profile": profile,
                "san": san,
                "expected": expected_domain,
                "actual": actual_domain,
                "instance": inst["name_tag"],
            })

    print()
    print("=" * 70)
    print(f"Match     : {len(match)}")
    print(f"Mismatch  : {len(mismatch)}  ← update local_domain in CSV before running batch")
    print(f"No SSM    : {len(no_ssm)}   ← verify manually or check SSM agent status")
    print(f"Auth fail : {len(auth_fail)}  ← fix profile or run aws sso login")

    if mismatch:
        print("\nMismatches — correct local_domain in CSV:")
        for r in mismatch:
            print(f"  {r['profile']}")
            print(f"    CSV has  : {r['expected']}")
            print(f"    Actual   : {r['actual']}  (from {r['instance']})")

    if auth_fail:
        print("\nAuth failures:")
        for r in auth_fail:
            print(f"  {r['profile']:<35} {r['error']}")

    if no_ssm:
        print("\nCould not verify via SSM (check manually):")
        for r in no_ssm:
            print(f"  {r['profile']:<35} {r['error']}")

    sys.exit(1 if mismatch or auth_fail else 0)


if __name__ == "__main__":
    main()
