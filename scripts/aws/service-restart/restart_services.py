"""
Foundation Service Restart Tool
Connect to Foundation OU servers via SSM and restart Windows services.

Usage:  python restart_services.py
Requires: pip install boto3
"""

import argparse
import os
import subprocess
import sys
import time
import boto3

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from aws_sso_helper import (
    resolve_account,
    load_all_profiles,
    ensure_profile_session,
    get_sso_session_for_profile,
    pick_profile_gui,
)

REGIONS = ["us-east-1", "us-west-2", "ca-central-1"]

def find_instances(profile, search_code):
    """Find EC2 instances matching search code (case-insensitive) across regions."""
    all_instances = []
    search_lower = search_code.lower()
    for region in REGIONS:
        print(f"  Searching {region}...", end=" ")
        session = boto3.Session(profile_name=profile, region_name=region)
        ec2 = session.client("ec2")
        paginator = ec2.get_paginator("describe_instances")
        pages = paginator.paginate(Filters=[
            {"Name": "instance-state-name", "Values": ["running"]},
        ])
        count = 0
        for page in pages:
            for res in page["Reservations"]:
                for inst in res["Instances"]:
                    name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "")
                    if search_lower not in name.lower():
                        continue
                    all_instances.append({
                        "InstanceId": inst["InstanceId"],
                        "Name": name or "N/A",
                        "PrivateIp": inst.get("PrivateIpAddress", "N/A"),
                        "Region": region,
                    })
                    count += 1
        print(f"{count} found.")
    return all_instances


def display_instances(instances):
    print(f"\n{'#':<4} {'Name':<30} {'Instance ID':<22} {'Private IP':<16} {'Region'}")
    print("-" * 100)
    for i, inst in enumerate(instances, 1):
        print(f"{i:<4} {inst['Name']:<30} {inst['InstanceId']:<22} {inst['PrivateIp']:<16} {inst['Region']}")


def check_ssm_online(profile, instance_id, region):
    session = boto3.Session(profile_name=profile, region_name=region)
    ssm = session.client("ssm")
    try:
        resp = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
        )
        info = resp.get("InstanceInformationList", [])
        return bool(info and info[0].get("PingStatus") == "Online")
    except Exception:
        return False


def run_ssm_command(profile, region, instance_id, script, timeout=60):
    session = boto3.Session(profile_name=profile, region_name=region)
    ssm = session.client("ssm")
    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunPowerShellScript",
            Parameters={"commands": [script]},
            TimeoutSeconds=timeout,
        )
    except Exception as e:
        return "", f"ERROR: {e}"
    cmd_id = resp["Command"]["CommandId"]
    for _ in range(30):
        time.sleep(2)
        try:
            inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
            if inv["Status"] in ("Success", "Failed", "TimedOut", "Cancelled"):
                stderr = inv.get("StandardErrorContent", "")
                if stderr:
                    print(f"  STDERR: {stderr.strip()}")
                return inv.get("StandardOutputContent", "").strip(), inv["Status"]
        except Exception:
            continue
    return "", "TimedOut"


def find_services(profile, region, instance_id, pattern):
    script = FIND_SERVICES_SCRIPT.format(pattern=pattern)
    stdout, status = run_ssm_command(profile, region, instance_id, script)
    if status != "Success" or "NO_SERVICES_FOUND" in stdout:
        return []
    services = []
    for line in stdout.strip().split("\n"):
        parts = line.strip().split("|")
        if len(parts) == 3:
            services.append({
                "ServiceName": parts[0],
                "DisplayName": parts[1],
                "Status": parts[2],
            })
    return services


def display_services(services):
    print(f"\n{'#':<4} {'Service Name':<45} {'Display Name':<55} {'Status'}")
    print("-" * 140)
    for i, svc in enumerate(services, 1):
        print(f"{i:<4} {svc['ServiceName']:<45} {svc['DisplayName']:<55} {svc['Status']}")


def restart_or_start_services(profile, region, instance_id, services, indices):
    for idx in indices:
        if 0 <= idx < len(services):
            svc = services[idx]
            name = svc["ServiceName"]
            current = svc["Status"]
            action = "Restarting" if current == "Running" else "Starting"
            print(f"\n  {action} {name} (currently {current})...", end=" ")

            script = RESTART_SERVICE_SCRIPT.format(service_name=name)
            stdout, status = run_ssm_command(profile, region, instance_id, script)

            if status == "Success" and stdout:
                parts = stdout.strip().split("|")
                if len(parts) == 3:
                    print(f"{parts[0]} - now {parts[2]}")
                else:
                    print(stdout.strip())
            else:
                print(f"FAILED (status: {status})")

            print(f"  Verifying {name}...", end=" ")
            script = CHECK_SERVICE_SCRIPT.format(service_name=name)
            stdout, _ = run_ssm_command(profile, region, instance_id, script)
            if stdout:
                parts = stdout.strip().split("|")
                if len(parts) == 3:
                    print(f"{parts[2]}")
                else:
                    print(stdout.strip())


def main():
    print("Loading Foundation OU profiles...")
    parser = argparse.ArgumentParser()
    parser.add_argument("--account", metavar="NAME",
                        help="Account name or nickname (e.g. PALegacyPlus, PLUS). "
                             "Omit to use the interactive picker.")
    args = parser.parse_args()

    if args.account:
        try:
            acct = resolve_account(args.account)
        except ValueError as e:
            print(f"Error: {e}")
            import sys; sys.exit(1)
        profile = acct["profile"]
        sso_session = acct["ssoSession"]
        print(f"Account: {acct['name']} ({acct['org']}, {acct['accountId']})")
        ensure_profile_session(profile, sso_session)
    else:
        profiles = load_all_profiles()
    if not profiles:
        print("No foundation profiles found in ~/.aws/config")
        sys.exit(1)

    print(f"Found {len(profiles)} profiles. Opening selector...")
    profile = pick_profile_gui(profiles)
    if not profile:
        print("No profile selected. Exiting.")
        sys.exit(0)
    print(f"\nSelected OU: {profile}")

    ensure_profile_session(profile, get_sso_session_for_profile(profile))

    while True:
        # Find server
        search_code = input("\nEnter server name or client code (e.g. REDB or REDB-PTRKWB001): ").strip()
        if not search_code:
            print("Search code required.")
            continue

        print(f"\nSearching for '{search_code}'...")
        instances = find_instances(profile, search_code)

        if not instances:
            print("\nNo instances found.")
            choice = input("\n[S] Search again in same OU  |  [D] Different OU  |  [C] Cancel: ").strip().lower()
            if choice == "s":
                continue
            elif choice == "d":
                profile = pick_profile_gui(profiles)
                if not profile:
                    sys.exit(0)
                print(f"\nSelected OU: {profile}")
                ensure_profile_session(profile, get_sso_session_for_profile(profile))
                continue
            else:
                sys.exit(0)

        display_instances(instances)

        sel = input("\nSelect server by number: ").strip()
        if not sel.isdigit() or int(sel) < 1 or int(sel) > len(instances):
            print("Invalid selection.")
            continue

        server = instances[int(sel) - 1]
        instance_id = server["InstanceId"]
        region = server["Region"]
        print(f"\nSelected: {server['Name']} ({instance_id}) - {region}")

        # Check SSM
        print("Checking SSM connectivity...", end=" ")
        if not check_ssm_online(profile, instance_id, region):
            print("OFFLINE - SSM agent not reachable.")
            print("  Ensure the instance has an IAM role with AmazonSSMManagedInstanceCore policy.")
            continue
        print("CONNECTED")

        # Service loop
        while True:
            pattern = input("\nEnter service name to search (e.g. Citrix, Superion, Trakit): ").strip()
            if not pattern:
                print("Search term required.")
                continue

            # Strip any user-added wildcards — script wraps with * automatically
            pattern = pattern.strip("*")
            print(f"Searching for services matching '*{pattern}*'...")
            services = find_services(profile, region, instance_id, pattern)

            if not services:
                print("No services found matching that pattern.")
                continue

            display_services(services)

            sel = input("\nSelect service(s) by number (comma-separated, e.g. 1,3): ").strip()
            indices = [int(x.strip()) - 1 for x in sel.split(",") if x.strip().isdigit()]
            valid = [i for i in indices if 0 <= i < len(services)]

            if not valid:
                print("No valid selection.")
                continue

            restart_or_start_services(profile, region, instance_id, services, valid)

            again = input("\nSearch for another service? (Y/N): ").strip().lower()
            if again != "y":
                break

        # After service work, ask what next
        choice = input("\n[S] Search another server in same OU  |  [D] Different OU  |  [C] Cancel: ").strip().lower()
        if choice == "s":
            continue
        elif choice == "d":
            profile = pick_profile_gui(profiles)
            if not profile:
                sys.exit(0)
            print(f"\nSelected OU: {profile}")
            ensure_profile_session(profile, get_sso_session_for_profile(profile))
            continue
        else:
            break

    print("\n=== Session complete ===")


if __name__ == "__main__":
    main()
