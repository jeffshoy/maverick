"""
Foundation Server Reboot Tool
Find EC2 instances by client/server code, show health status, reboot, and wait for online.

Usage:  python reboot_server.py
Requires: pip install boto3
"""

import argparse
import os
import subprocess
import sys
import time

import boto3

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from aws_sso_helper import (
    resolve_account,
    load_all_profiles,
    ensure_profile_session,
    get_sso_session_for_profile,
    pick_profile_gui,
)

REGIONS = ["us-east-1", "us-west-2", "ca-central-1"]


def find_instances(profile, search_code):
    """Find EC2 instances matching the search code (case-insensitive) across regions."""
    all_instances = []
    search_lower = search_code.lower()

    for region in REGIONS:
        print(f"  Searching {region}...", end=" ")
        session = boto3.Session(profile_name=profile, region_name=region)
        ec2 = session.client("ec2")

        # Fetch all non-terminated instances, filter by name locally (case-insensitive)
        paginator = ec2.get_paginator("describe_instances")
        pages = paginator.paginate(Filters=[
            {"Name": "instance-state-name", "Values": ["running", "stopped", "stopping", "pending"]},
        ])

        instance_ids = []
        instances_map = {}
        pages_cache = list(pages)
        for page in pages_cache:
            for res in page["Reservations"]:
                for inst in res["Instances"]:
                    name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "")
                    if search_lower not in name.lower():
                        continue
                    iid = inst["InstanceId"]
                    instances_map[iid] = {
                        "InstanceId": iid,
                        "Name": name or "N/A",
                        "State": inst["State"]["Name"],
                        "PrivateIp": inst.get("PrivateIpAddress", "N/A"),
                        "Region": region,
                        "HealthChecks": "N/A",
                    }
                    instance_ids.append(iid)

        # Fetch status checks (system + instance + EBS)
        if instance_ids:
            try:
                status_resp = ec2.describe_instance_status(
                    InstanceIds=instance_ids, IncludeAllInstances=True
                )
                # Build EBS volume map for attached volumes
                vol_map = {}  # instance_id -> [volume_ids]
                for iid in instance_ids:
                    vols = instances_map[iid].get("_volumes", [])
                    vol_map[iid] = vols

                # Get EBS volume statuses
                all_vol_ids = []
                for res in pages_cache:
                    for r in res["Reservations"]:
                        for inst in r["Instances"]:
                            iid = inst["InstanceId"]
                            if iid in instances_map:
                                vids = [b["Ebs"]["VolumeId"] for b in inst.get("BlockDeviceMappings", []) if "Ebs" in b]
                                vol_map[iid] = vids
                                all_vol_ids.extend(vids)

                ebs_status = {}  # volume_id -> status
                if all_vol_ids:
                    try:
                        vol_resp = ec2.describe_volume_status(VolumeIds=all_vol_ids)
                        for vs in vol_resp.get("VolumeStatuses", []):
                            ebs_status[vs["VolumeId"]] = vs.get("VolumeStatus", {}).get("Status", "N/A")
                    except Exception:
                        pass

                for s in status_resp.get("InstanceStatuses", []):
                    iid = s["InstanceId"]
                    sys_st = s.get("SystemStatus", {}).get("Status", "N/A")
                    inst_st = s.get("InstanceStatus", {}).get("Status", "N/A")

                    # EBS check for this instance
                    vols = vol_map.get(iid, [])
                    ebs_ok = all(ebs_status.get(v) == "ok" for v in vols) if vols else None
                    ebs_st = "ok" if ebs_ok else ("impaired" if ebs_ok is False else "N/A")

                    passed = sum(1 for st in [sys_st, inst_st, ebs_st] if st == "ok")
                    health = f"{passed}/3 (sys:{sys_st} inst:{inst_st} ebs:{ebs_st})"
                    if iid in instances_map:
                        instances_map[iid]["HealthChecks"] = health
            except Exception as e:
                print(f"(health check error: {e})", end=" ")

        found = list(instances_map.values())
        print(f"{len(found)} found.")
        all_instances.extend(found)

    return all_instances


def display_instances(instances):
    print(f"\n{'#':<4} {'Name':<30} {'Instance ID':<22} {'State':<10} {'Private IP':<16} {'Health Checks':<30} {'Region'}")
    print("-" * 145)
    for i, inst in enumerate(instances, 1):
        print(f"{i:<4} {inst['Name']:<30} {inst['InstanceId']:<22} {inst['State']:<10} {inst['PrivateIp']:<16} {inst['HealthChecks']:<30} {inst['Region']}")


def reboot_instance(profile, instance_id, region):
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")
    print(f"  Rebooting {instance_id}...", end=" ")
    ec2.reboot_instances(InstanceIds=[instance_id])
    print("reboot command sent.")


def wait_for_online(profile, instance_id, region, ip, timeout=300):
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")

    if ip and ip != "N/A":
        print(f"  Pinging {ip}...", end="", flush=True)
        start = time.time()
        was_down = False
        while time.time() - start < timeout:
            ret = subprocess.call(
                ["ping", "-n", "1", "-w", "1000", ip],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            if ret != 0:
                was_down = True
                print(".", end="", flush=True)
                time.sleep(3)
            elif was_down:
                print(f" ONLINE!")
                break
            else:
                print(".", end="", flush=True)
                time.sleep(3)
        else:
            print(f" TIMEOUT after {timeout}s")

    print(f"  Waiting for health checks on {instance_id}...", end="", flush=True)
    start = time.time()
    while time.time() - start < timeout:
        try:
            resp = ec2.describe_instance_status(
                InstanceIds=[instance_id], IncludeAllInstances=True
            )
            statuses = resp.get("InstanceStatuses", [])
            if statuses:
                s = statuses[0]
                sys_ok = s.get("SystemStatus", {}).get("Status") == "ok"
                inst_ok = s.get("InstanceStatus", {}).get("Status") == "ok"
                if sys_ok and inst_ok:
                    print(f" ALL CHECKS PASSED!")
                    return True
        except Exception:
            pass
        print(".", end="", flush=True)
        time.sleep(5)
    print(f" TIMEOUT waiting for health checks.")
    return False


def show_final_status(profile, instance_ids, region):
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")
    resp = ec2.describe_instance_status(
        InstanceIds=instance_ids, IncludeAllInstances=True
    )
    # Get EBS statuses
    inst_resp = ec2.describe_instances(InstanceIds=instance_ids)
    vol_map = {}
    for res in inst_resp["Reservations"]:
        for inst in res["Instances"]:
            vids = [b["Ebs"]["VolumeId"] for b in inst.get("BlockDeviceMappings", []) if "Ebs" in b]
            vol_map[inst["InstanceId"]] = vids
    all_vols = [v for vids in vol_map.values() for v in vids]
    ebs_status = {}
    if all_vols:
        try:
            vr = ec2.describe_volume_status(VolumeIds=all_vols)
            for vs in vr.get("VolumeStatuses", []):
                ebs_status[vs["VolumeId"]] = vs.get("VolumeStatus", {}).get("Status", "N/A")
        except Exception:
            pass

    print(f"\n{'Instance ID':<22} {'System':<12} {'Instance':<12} {'EBS'}")
    print("-" * 55)
    for s in resp.get("InstanceStatuses", []):
        iid = s["InstanceId"]
        sys_s = s.get("SystemStatus", {}).get("Status", "N/A")
        inst_s = s.get("InstanceStatus", {}).get("Status", "N/A")
        vols = vol_map.get(iid, [])
        ebs_ok = all(ebs_status.get(v) == "ok" for v in vols) if vols else None
        ebs_s = "ok" if ebs_ok else ("impaired" if ebs_ok is False else "N/A")
        print(f"{iid:<22} {sys_s:<12} {inst_s:<12} {ebs_s}")


def main():
    parser = argparse.ArgumentParser(description="Reboot EC2 instances via SSM.")
    parser.add_argument("--account", metavar="NAME",
                        help="Account name or nickname (e.g. PALegacyPlus, PLUS). "
                             "Omit to use the interactive picker.")
    args = parser.parse_args()

    if args.account:
        try:
            acct = resolve_account(args.account)
        except ValueError as e:
            print(f"Error: {e}")
            sys.exit(1)
        profile = acct["profile"]
        sso_session = acct["ssoSession"]
        print(f"Account: {acct['name']} ({acct['org']}, {acct['accountId']})")
    else:
        profiles = load_all_profiles()
        if not profiles:
            print("No profiles found in accounts.json")
            sys.exit(1)
        print(f"Found {len(profiles)} profiles. Opening selector...")
        profile = pick_profile_gui(profiles)
        if not profile:
            print("No profile selected. Exiting.")
            sys.exit(0)
        sso_session = get_sso_session_for_profile(profile)

    print(f"\nSelected OU: {profile}")
    ensure_profile_session(profile, sso_session)

    while True:
        search_code = input("\nEnter client code or server name (e.g. REDB or REDB-PTRKWB001): ").strip()
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
                print("\nOpening OU selector...")
                profile = pick_profile_gui(profiles)
                if not profile:
                    print("No profile selected. Exiting.")
                    sys.exit(0)
                print(f"\nSelected OU: {profile}")
                ensure_profile_session(profile, get_sso_session_for_profile(profile))
                continue
            else:
                print("Exiting.")
                sys.exit(0)

        display_instances(instances)

        sel = input("\nSelect server(s) by number (comma-separated, e.g. 1,2): ").strip()
        indices = [int(x.strip()) - 1 for x in sel.split(",") if x.strip().isdigit()]
        selected = [instances[i] for i in indices if 0 <= i < len(instances)]

        if not selected:
            print("No valid selection.")
            continue

        print("\nSelected:")
        for s in selected:
            print(f"  {s['Name']} ({s['InstanceId']}) \u2014 {s['State']} \u2014 {s['Region']}")

        confirm = input("\nReboot selected server(s)? (Y/N): ").strip().lower()
        if confirm != "y":
            print("Skipped.")
        else:
            for inst in selected:
                reboot_instance(profile, inst["InstanceId"], inst["Region"])
                wait_for_online(profile, inst["InstanceId"], inst["Region"], inst["PrivateIp"])

            by_region = {}
            for s in selected:
                by_region.setdefault(s["Region"], []).append(s["InstanceId"])
            print("\n=== Final Status ===")
            for region, ids in by_region.items():
                show_final_status(profile, ids, region)

        choice = input("\n[S] Search again in same OU  |  [D] Different OU  |  [C] Cancel: ").strip().lower()
        if choice == "s":
            continue
        elif choice == "d":
            print("\nOpening OU selector...")
            profile = pick_profile_gui(profiles)
            if not profile:
                print("No profile selected. Exiting.")
                sys.exit(0)
            print(f"\nSelected OU: {profile}")
            ensure_profile_session(profile, get_sso_session_for_profile(profile))
            continue
        else:
            break

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
