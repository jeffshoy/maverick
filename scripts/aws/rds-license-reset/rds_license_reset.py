"""
RDS License Reset CLI
Resets Terminal Server grace period to 120 days via AWS SSM, then force-reboots and verifies.

Usage:  python rds_license_reset.py
Requires: pip install boto3
"""

import argparse
import os
import subprocess
import sys
import json
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

def get_client(profile, service, region):
    return boto3.Session(profile_name=profile, region_name=region).client(service)


# =============================================================================
# SSM Document
# =============================================================================
def ensure_document(profile, region):
    ssm = get_client(profile, "ssm", region)
    try:
        ssm.describe_document(Name=DOC_NAME)
        print(f"  SSM document '{DOC_NAME}' exists in {region}.")
    except ssm.exceptions.InvalidDocument:
        print(f"  Creating SSM document '{DOC_NAME}' in {region}...")
        ssm.create_document(
            Content=json.dumps(SSM_DOC), Name=DOC_NAME,
            DocumentType="Command", DocumentFormat="JSON",
        )
        print("  Created.")


# =============================================================================
# EC2 Discovery — supports client code OR server name wildcard
# =============================================================================
def find_instances(profile, search_term):
    all_inst = []
    search_lower = search_term.lower()
    for region in REGIONS:
        print(f"  Searching {region}...", end=" ")
        session = boto3.Session(profile_name=profile, region_name=region)
        ec2 = session.client("ec2")
        paginator = ec2.get_paginator("describe_instances")
        pages = paginator.paginate(Filters=[
            {"Name": "instance-state-name", "Values": ["running", "stopped"]},
        ])
        count = 0
        for page in pages:
            for res in page["Reservations"]:
                for i in res["Instances"]:
                    name = next((t["Value"] for t in i.get("Tags", []) if t["Key"] == "Name"), "")
                    if search_lower not in name.lower():
                        continue
                    all_inst.append({
                        "InstanceId": i["InstanceId"], "Name": name or "N/A",
                        "State": i["State"]["Name"],
                        "PrivateIp": i.get("PrivateIpAddress", "N/A"),
                        "Region": region,
                    })
                    count += 1
        print(f"{count} found.")
    return all_inst


def display_instances(instances):
    print(f"\n{'#':<4} {'Name':<30} {'Instance ID':<22} {'State':<10} {'Private IP':<16} {'Region'}")
    print("-" * 110)
    for i, inst in enumerate(instances, 1):
        print(f"{i:<4} {inst['Name']:<30} {inst['InstanceId']:<22} {inst['State']:<10} {inst['PrivateIp']:<16} {inst['Region']}")


# =============================================================================
# SSM Execution helpers
# =============================================================================
def run_ssm_command(profile, region, instance_id, script, timeout=60):
    ssm = get_client(profile, "ssm", region)
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


def check_grace_period(profile, region, instance_id):
    """Check current RDS grace period days. Returns int or None on error."""
    stdout, status = run_ssm_command(profile, region, instance_id, CHECK_GRACE_SCRIPT)
    if status == "Success" and stdout:
        for line in stdout.split("\n"):
            if line.startswith("RDS_GRACE_DAYS="):
                val = line.split("=", 1)[1].strip()
                if val.isdigit():
                    return int(val)
                print(f"  Grace period query returned: {val}")
                return None
    return None


def run_reset(profile, region, instance_ids):
    ssm = get_client(profile, "ssm", region)
    print(f"\nSending reset command to {instance_ids} in {region}...")
    resp = ssm.send_command(
        InstanceIds=instance_ids, DocumentName=DOC_NAME,
        TimeoutSeconds=120, Comment="RDS License Grace Period Reset",
    )
    cmd_id = resp["Command"]["CommandId"]
    print(f"Command ID: {cmd_id}")

    for iid in instance_ids:
        print(f"\nWaiting for command on {iid}...")
        try:
            ssm.get_waiter("command_executed").wait(
                CommandId=cmd_id, InstanceId=iid,
                WaiterConfig={"Delay": 5, "MaxAttempts": 30},
            )
        except Exception:
            pass  # instance reboots mid-command
        try:
            out = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=iid)
            print(f"  Status: {out['Status']}")
            if out.get("StandardOutputContent"):
                print(f"  Output: {out['StandardOutputContent'].strip()}")
            if out.get("StandardErrorContent"):
                print(f"  Errors: {out['StandardErrorContent'].strip()}")
        except Exception as e:
            print(f"  Could not retrieve output (instance likely rebooting): {e}")
    return cmd_id


# =============================================================================
# Wait & Verify
# =============================================================================
def ping_until_online(ip, timeout=300):
    print(f"\nPinging {ip} until online (timeout {timeout}s)...")
    start = time.time()
    while time.time() - start < timeout:
        ret = subprocess.call(
            ["ping", "-n", "1", "-w", "1000", ip],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if ret == 0:
            print(f"  {ip} is ONLINE.")
            return True
        time.sleep(3)
    print(f"  TIMEOUT: {ip} not reachable within {timeout}s.")
    return False


def wait_ssm_online(profile, region, instance_id, timeout=300):
    ssm = get_client(profile, "ssm", region)
    print(f"Waiting for SSM agent on {instance_id}...")
    start = time.time()
    while time.time() - start < timeout:
        try:
            resp = ssm.describe_instance_information(
                Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
            )
            info = resp.get("InstanceInformationList", [])
            if info and info[0].get("PingStatus") == "Online":
                print(f"  SSM agent on {instance_id} is Online.")
                return True
        except Exception:
            pass
        time.sleep(5)
    print(f"  TIMEOUT: SSM agent not online within {timeout}s.")
    return False


def verify_license(profile, region, instance_id):
    print(f"\nVerifying license on {instance_id}...")
    stdout, status = run_ssm_command(profile, region, instance_id, CHECK_GRACE_SCRIPT)
    if status == "Success" and stdout:
        print(f"  {stdout.strip()}")
    else:
        print(f"  Verification failed (status: {status})")


# =============================================================================
# Main
# =============================================================================
def main():
    # 0. Load profiles and pick OU
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

    # 1. SSO login
    ensure_profile_session(profile, get_sso_session_for_profile(profile))

    while True:
        # 2. Search — client code or server name wildcard
        print("\nEnter a client code (e.g. ARCT) or server name (e.g. ARCT-PTRKRD001).")
        print("Wildcards supported: partial matches work (e.g. 'TRKRD' matches all TRKRD servers).")
        search_term = input("> ").strip()
        if not search_term:
            print("Search term is required.")
            continue

        # 3. Region
        r = input("Region — [E]ast / [W]est / [Enter] for both: ").strip().lower()
        if r == "e":
            search_regions = ["us-east-1"]
        elif r == "w":
            search_regions = ["us-west-2"]
        else:
            search_regions = list(REGIONS)

        # Temporarily override REGIONS for find_instances
        original_regions = REGIONS.copy()
        REGIONS.clear()
        REGIONS.extend(search_regions)

        # 4. Ensure SSM doc
        for reg in search_regions:
            ensure_document(profile, reg)

        # 5. Find instances
        print(f"\nSearching for '{search_term}'...")
        all_inst = find_instances(profile, search_term)

        REGIONS.clear()
        REGIONS.extend(original_regions)

        if not all_inst:
            print("\nNo matching instances found.")
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

        display_instances(all_inst)

        # 6. Select
        sel = input("\nSelect instance(s) by number (comma-separated, e.g. 1,3): ").strip()
        indices = [int(x.strip()) - 1 for x in sel.split(",") if x.strip().isdigit()]
        selected = [all_inst[i] for i in indices if 0 <= i < len(all_inst)]
        if not selected:
            print("No valid selection.")
            continue

        print("\nSelected:")
        for s in selected:
            print(f"  {s['Name']} ({s['InstanceId']}) — {s['Region']}")

        # 7. Check grace period on each selected instance BEFORE resetting
        print("\n--- Checking current grace period on selected instances ---")
        to_reset = []
        for inst in selected:
            iid = inst["InstanceId"]
            region = inst["Region"]
            print(f"\n  {inst['Name']} ({iid})...", end=" ")
            grace_days = check_grace_period(profile, region, iid)

            if grace_days is None:
                print("Could not determine grace period.")
                resp = input(f"  Proceed with reset anyway for {inst['Name']}? (Y/N): ").strip().lower()
                if resp == "y":
                    to_reset.append(inst)
                else:
                    print(f"  Skipping {inst['Name']}.")
            elif grace_days == 0:
                print(f"Grace period: {grace_days} days (EXPIRED)")
                print(f"  Grace period is 0 — reset will be applied automatically.")
                to_reset.append(inst)
            else:
                print(f"Grace period: {grace_days} days remaining")
                resp = input(f"  Grace period is NOT 0 ({grace_days} days left). Apply reset? (Y/N): ").strip().lower()
                if resp == "y":
                    to_reset.append(inst)
                else:
                    print(f"  Skipping {inst['Name']}.")

        if not to_reset:
            print("\nNo instances selected for reset.")
            choice = input("\n[S] Search again  |  [D] Different OU  |  [C] Cancel: ").strip().lower()
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

        # 8. Final confirmation
        print(f"\n--- Will reset RDS grace period on {len(to_reset)} instance(s): ---")
        for inst in to_reset:
            print(f"  {inst['Name']} ({inst['InstanceId']}) — {inst['Region']}")
        print("\nThis will DELETE the grace period registry key and FORCE REBOOT the server(s).")
        confirm = input("Type 'yes' to proceed: ").strip().lower()
        if confirm != "yes":
            print("Cancelled.")
            continue

        # 9. Execute by region
        by_region = {}
        for s in to_reset:
            by_region.setdefault(s["Region"], []).append(s)

        for region, insts in by_region.items():
            ids = [i["InstanceId"] for i in insts]
            run_reset(profile, region, ids)

            for inst in insts:
                ip, iid = inst["PrivateIp"], inst["InstanceId"]
                if ip and ip != "N/A":
                    ping_until_online(ip)
                wait_ssm_online(profile, region, iid)
                verify_license(profile, region, iid)

        print("\n=== Reset complete ===")

        # 10. Continue or exit
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
            break

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
