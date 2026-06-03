"""
Foundation Disk Expand Tool
Expand EBS volumes and resize OS partitions on Foundation OU servers via SSM.

Usage:  python expand_disk.py
Requires: pip install boto3
"""

import argparse
import os
import subprocess
import sys
import math
import re
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
        for page in pages:
            for res in page["Reservations"]:
                for inst in res["Instances"]:
                    name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "")
                    if search_lower not in name.lower():
                        continue
                    all_instances.append({
                        "InstanceId": inst["InstanceId"],
                        "Name": name or "N/A",
                        "State": inst["State"]["Name"],
                        "PrivateIp": inst.get("PrivateIpAddress", "N/A"),
                        "Region": region,
                    })
        print(f"{sum(1 for i in all_instances if i['Region'] == region)} found.")
    return all_instances


def display_instances(instances):
    print(f"\n{'#':<4} {'Name':<30} {'Instance ID':<22} {'State':<10} {'Private IP':<16} {'Region'}")
    print("-" * 110)
    for i, inst in enumerate(instances, 1):
        print(f"{i:<4} {inst['Name']:<30} {inst['InstanceId']:<22} {inst['State']:<10} {inst['PrivateIp']:<16} {inst['Region']}")


def check_ssm_available(profile, region, instance_id):
    """Check if SSM agent is online on the instance."""
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
    except ssm.exceptions.InvalidInstanceId:
        return "", "SSM_NOT_AVAILABLE"
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


def get_ebs_volumes(profile, region, instance_id):
    """Get EBS volumes attached to the instance."""
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    volumes = []
    for res in resp["Reservations"]:
        for inst in res["Instances"]:
            for bdm in inst.get("BlockDeviceMappings", []):
                if "Ebs" in bdm:
                    vol_id = bdm["Ebs"]["VolumeId"]
                    device = bdm["DeviceName"]
                    vol_resp = ec2.describe_volumes(VolumeIds=[vol_id])
                    for v in vol_resp["Volumes"]:
                        volumes.append({
                            "VolumeId": vol_id,
                            "Device": device,
                            "SizeGB": v["Size"],
                            "VolumeType": v["VolumeType"],
                            "State": v["State"],
                        })
    return volumes


def get_os_drives(profile, region, instance_id):
    """Get drive letters and sizes from inside the OS via SSM."""
    print("  Fetching OS drive info via SSM...", end=" ")
    stdout, status = run_ssm_command(profile, region, instance_id, GET_DRIVES_SCRIPT)
    if status != "Success":
        print(f"FAILED ({status})")
        return []
    print("OK")
    drives = []
    for line in stdout.strip().split("\n"):
        parts = line.strip().split("|")
        if len(parts) == 4:
            drives.append({
                "DriveLetter": parts[0],
                "DiskNumber": parts[1],
                "SizeGB": parts[2],
                "VolumeId": parts[3],
            })
    return drives


def display_combined_drives(ebs_volumes, os_drives):
    """Display EBS volumes matched with OS drive letters."""
    # Match EBS volumes to OS drives by volume ID (normalize to strip suffixes like _00000001)
    drive_map = {}
    for d in os_drives:
        if d["VolumeId"]:
            clean_id = re.sub(r'[._].*$', '', d["VolumeId"]).strip()
            drive_map[clean_id] = d

    print(f"\n{'#':<4} {'Drive':<8} {'EBS Volume ID':<24} {'Device':<15} {'EBS Size (GB)':<15} {'OS Size (GB)':<15} {'Type'}")
    print("-" * 100)
    combined = []
    idx = 1
    for vol in ebs_volumes:
        vid = vol["VolumeId"]
        os_info = drive_map.get(vid, {})
        letter = os_info.get("DriveLetter", "?")
        os_size = os_info.get("SizeGB", "?")
        print(f"{idx:<4} {letter}:\\{'':<5} {vid:<24} {vol['Device']:<15} {vol['SizeGB']:<15} {os_size:<15} {vol['VolumeType']}")
        combined.append({
            "VolumeId": vid,
            "Device": vol["Device"],
            "EBSSizeGB": vol["SizeGB"],
            "OSSizeGB": os_size,
            "DriveLetter": letter,
            "VolumeType": vol["VolumeType"],
        })
        idx += 1

    # Show any OS drives not matched to EBS (unlikely but possible)
    matched_vids = {v["VolumeId"] for v in ebs_volumes}
    for d in os_drives:
        if d["VolumeId"] and d["VolumeId"] not in matched_vids:
            print(f"{idx:<4} {d['DriveLetter']}:\\{'':<5} {d['VolumeId']:<24} {'?':<15} {'?':<15} {d['SizeGB']:<15} {'?'}")
            combined.append({
                "VolumeId": d["VolumeId"],
                "Device": "?",
                "EBSSizeGB": "?",
                "OSSizeGB": d["SizeGB"],
                "DriveLetter": d["DriveLetter"],
                "VolumeType": "?",
            })
            idx += 1

    return combined


def expand_ebs_volume(profile, region, volume_id, new_size_gb):
    """Modify EBS volume size."""
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")
    print(f"  Expanding EBS volume {volume_id} to {new_size_gb} GB...", end=" ")
    ec2.modify_volume(VolumeId=volume_id, Size=new_size_gb)
    print("modification requested.")

    # Wait for optimization/completion
    print(f"  Waiting for volume modification to complete...", end="", flush=True)
    for _ in range(60):
        time.sleep(5)
        resp = ec2.describe_volumes_modifications(VolumeIds=[volume_id])
        mods = resp.get("VolumesModifications", [])
        if mods:
            state = mods[0].get("ModificationState", "")
            if state in ("completed", "optimizing"):
                print(f" {state}!")
                return True
        print(".", end="", flush=True)
    print(" TIMEOUT")
    return False


def expand_os_partition(profile, region, instance_id, drive_letter):
    """Expand the OS partition to use the new EBS space."""
    print(f"  Expanding partition {drive_letter}:\\ on the server...", end=" ")
    script = EXPAND_PARTITION_SCRIPT.format(drive_letter=drive_letter)
    stdout, status = run_ssm_command(profile, region, instance_id, script, timeout=120)
    if status != "Success":
        print(f"FAILED ({status})")
        return
    print("OK")

    # Parse result
    for line in stdout.strip().split("\n"):
        if line.startswith("RESULT|"):
            parts = line.split("|")
            if len(parts) == 5:
                print(f"\n  Drive {parts[1]}:\\")
                print(f"    Used:  {parts[2]} GB")
                print(f"    Free:  {parts[3]} GB")
                print(f"    Total: {parts[4]} GB")
                return
    print(f"  Output: {stdout}")


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
        # 1. Find server
        search_code = input("\nEnter server name or client code (e.g. PIED or PIED-PTRKWB001): ").strip()
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
        iid = server["InstanceId"]
        region = server["Region"]
        print(f"\nSelected: {server['Name']} ({iid}) - {region}")

        # 2. Check SSM availability
        print("\nChecking SSM connectivity...", end=" ")
        if not check_ssm_available(profile, region, iid):
            print("OFFLINE")
            print("  SSM agent is not available on this instance.")
            print("  Ensure the instance has an IAM role with AmazonSSMManagedInstanceCore policy")
            print("  and the SSM agent is installed and running.")
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
        print("CONNECTED")

        # 3. Get EBS volumes + OS drives
        print("\nFetching disk information...")
        ebs_volumes = get_ebs_volumes(profile, region, iid)
        os_drives = get_os_drives(profile, region, iid)
        combined = display_combined_drives(ebs_volumes, os_drives)

        if not combined:
            print("No drives found.")
            continue

        # 3. Select drive
        drive_sel = input("\nSelect drive by number: ").strip()
        if not drive_sel.isdigit() or int(drive_sel) < 1 or int(drive_sel) > len(combined):
            print("Invalid selection.")
            continue

        drive = combined[int(drive_sel) - 1]
        current_size = drive["EBSSizeGB"]
        print(f"\nSelected: {drive['DriveLetter']}:\\ — Volume {drive['VolumeId']} — Current EBS size: {current_size} GB")

        # 4. Ask for new size and confirm
        while True:
            new_size_input = input(f"\nEnter new TOTAL size in GB (not extra space, must be > {current_size}): ").strip()
            if not new_size_input.isdigit():
                print("  Please enter a valid number.")
                continue
            new_size = int(new_size_input)
            if new_size <= current_size:
                print(f"  Must be greater than current size ({current_size} GB). This is the TOTAL disk size, not extra space.")
                continue
            break

        while True:
            resp = input(f"\nExpand {drive['DriveLetter']}:\\ from {current_size} GB to {new_size} GB TOTAL? Type 'yes' to proceed or 'no' to cancel: ").strip().lower()
            if resp == "yes":
                break
            if resp == "no":
                print("Cancelled.")
                continue  # back to outer while loop
            print("  Please type 'yes' to proceed or 'no' to cancel.")
        if resp == "no":
            continue

        # 5. Expand EBS volume
        success = expand_ebs_volume(profile, region, drive["VolumeId"], new_size)
        if not success:
            print("EBS expansion may still be in progress. Proceeding with partition expand...")

        # 6. Expand OS partition
        expand_os_partition(profile, region, iid, drive["DriveLetter"])

        print("\n=== Disk expansion complete ===")

        # 7. Continue or exit
        choice = input("\n[S] Expand another disk on same server  |  [N] New server  |  [D] Different OU  |  [C] Cancel: ").strip().lower()
        if choice == "s":
            # Re-fetch and show drives for same server
            print("\nRefreshing disk information...")
            ebs_volumes = get_ebs_volumes(profile, region, iid)
            os_drives = get_os_drives(profile, region, iid)
            combined = display_combined_drives(ebs_volumes, os_drives)
            if not combined:
                print("No drives found.")
                continue
            drive_sel = input("\nSelect drive by number: ").strip()
            if not drive_sel.isdigit() or int(drive_sel) < 1 or int(drive_sel) > len(combined):
                print("Invalid selection.")
                continue
            drive = combined[int(drive_sel) - 1]
            current_size = drive["EBSSizeGB"]
            print(f"\nSelected: {drive['DriveLetter']}:\\ — Volume {drive['VolumeId']} — Current EBS size: {current_size} GB")
            while True:
                new_size_input = input(f"\nEnter new TOTAL size in GB (not extra space, must be > {current_size}): ").strip()
                if not new_size_input.isdigit():
                    print("  Please enter a valid number.")
                    continue
                new_size = int(new_size_input)
                if new_size <= current_size:
                    print(f"  Must be greater than current size ({current_size} GB). This is the TOTAL disk size, not extra space.")
                    continue
                break
            while True:
                resp = input(f"\nExpand {drive['DriveLetter']}:\\ from {current_size} GB to {new_size} GB TOTAL? Type 'yes' to proceed or 'no' to cancel: ").strip().lower()
                if resp == "yes":
                    break
                if resp == "no":
                    print("Cancelled.")
                    break
                print("  Please type 'yes' to proceed or 'no' to cancel.")
            if resp != "yes":
                continue
            expand_ebs_volume(profile, region, drive["VolumeId"], new_size)
            expand_os_partition(profile, region, iid, drive["DriveLetter"])
            print("\n=== Disk expansion complete ===")
        elif choice == "n":
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
