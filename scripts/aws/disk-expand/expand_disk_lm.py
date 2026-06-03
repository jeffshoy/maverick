"""
Foundation Disk Expand (LogicMonitor Integration)
Parses LM disk alert details, compares historical vs current usage, generates RFC summary,
and expands EBS + OS partition on confirmation.

Usage:  python expand_disk_lm.py
Requires: pip install boto3
"""

import argparse
import os
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

EXPAND_PARTITION_SCRIPT = r'''
$DriveLetter = '{drive_letter}'
$DiskNumber = (Get-Partition -DriveLetter $DriveLetter).DiskNumber
Get-Disk -Number $DiskNumber | Update-Disk
Start-Sleep -Seconds 2
Resize-Partition -DriveLetter $DriveLetter -Size (Get-PartitionSupportedSize -DriveLetter $DriveLetter).SizeMax
Start-Sleep -Seconds 2
$drv = Get-PSDrive -Name $DriveLetter
$used = [Math]::Round($drv.Used / 1GB, 2)
$free = [Math]::Round($drv.Free / 1GB, 2)
$total = [Math]::Round(($drv.Used + $drv.Free) / 1GB, 2)
Write-Output "RESULT|$DriveLetter|$used|$free|$total"
'''

GET_DRIVES_SCRIPT = r'''
Get-Partition | Where-Object { $_.DriveLetter -ne "`0" } | ForEach-Object {
    $letter = $_.DriveLetter
    $diskNum = $_.DiskNumber
    $sizeGB = [Math]::Round($_.Size / 1GB, 2)
    $disk = Get-Disk -Number $diskNum
    $serialRaw = $disk.SerialNumber
    $volId = ""
    if ($serialRaw -match "^vol") {
        $volId = $serialRaw -replace "^vol", "vol-"
        $volId = $volId -replace '[._].*$', ''
        $volId = $volId.Trim()
    }
    Write-Output "$letter|$diskNum|$sizeGB|$volId"
}
'''

GET_DISK_USAGE_SCRIPT = r'''
$DriveLetter = '{drive_letter}'
$drv = Get-PSDrive -Name $DriveLetter
$used = [Math]::Round($drv.Used / 1GB, 2)
$free = [Math]::Round($drv.Free / 1GB, 2)
$total = [Math]::Round(($drv.Used + $drv.Free) / 1GB, 2)
Write-Output "USAGE|$DriveLetter|$used|$free|$total"
'''


# =============================================================================
# Alert Parsing
# =============================================================================
def parse_alert_input():
    """Parse alert details from user input — supports pasted LM alert text."""
    print("\n=== LogicMonitor Alert Details ===")
    print("Paste the alert info below (from LM email, Teams, or the alert page).")
    print("You can paste the full block or just answer the prompts.\n")

    print("Enter the Host/Server name from the alert")
    print("  (e.g. REDB-PTRKWB001.aspgov.pri or just REDB-PTRKWB001)")
    host = input("> ").strip()
    server_name = host.split(".")[0] if host else None

    print("\nEnter the Drive letter from the alert")
    print("  (e.g. C or E — look at the Datasource name like 'WinVolumeUsage-C:')")
    drive_letter = input("> ").strip().upper().replace(":", "")

    print("\nEnter Datacenter")
    print("  (e.g. Vegas or Voorhees — check the Group field in the alert)")
    datacenter = input("> ").strip()
    if not datacenter:
        datacenter = "Vegas"

    print("\nEnter the alert threshold or current usage % (optional, press Enter to skip)")
    threshold = input("> ").strip()

    return {
        "server_name": server_name,
        "host_fqdn": host,
        "drive_letter": drive_letter,
        "datacenter": datacenter,
        "threshold": threshold,
    }


def parse_pasted_block():
    """Alternative: parse a full pasted alert block."""
    print("\n=== Paste Full Alert Block ===")
    print("Paste the alert details and press Enter twice when done:\n")

    lines = []
    empty_count = 0
    while True:
        line = input()
        if line.strip() == "":
            empty_count += 1
            if empty_count >= 2:
                break
        else:
            empty_count = 0
            lines.append(line)

    text = "\n".join(lines)
    result = {
        "server_name": None,
        "host_fqdn": None,
        "drive_letter": None,
        "datacenter": None,
        "threshold": None,
    }

    host_match = re.search(r"Host[:\s]+(\S+)", text, re.IGNORECASE)
    if host_match:
        result["host_fqdn"] = host_match.group(1)
        result["server_name"] = host_match.group(1).split(".")[0]

    ds_match = re.search(r"(?:Datasource|DataSource)[:\s]+(.*)", text, re.IGNORECASE)
    if ds_match:
        drive_match = re.search(r"([A-Z])[\:\\]", ds_match.group(1), re.IGNORECASE)
        if drive_match:
            result["drive_letter"] = drive_match.group(1).upper()

    group_match = re.search(r"Group[:\s]+(.*)", text, re.IGNORECASE)
    if group_match:
        group_text = group_match.group(1)
        if "vegas" in group_text.lower():
            result["datacenter"] = "Vegas"
        elif "voorhees" in group_text.lower():
            result["datacenter"] = "Voorhees"

    val_match = re.search(r"Value[:\s]+(\S+)", text, re.IGNORECASE)
    if val_match:
        result["threshold"] = val_match.group(1)

    return result


# =============================================================================
# AWS / SSM helpers
# =============================================================================
def find_instances(profile, search_code):
    all_instances = []
    search_lower = search_code.lower()
    for region in REGIONS:
        session = boto3.Session(profile_name=profile, region_name=region)
        ec2 = session.client("ec2")
        paginator = ec2.get_paginator("describe_instances")
        for page in paginator.paginate(Filters=[{"Name": "instance-state-name", "Values": ["running"]}]):
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
    return all_instances


def check_ssm_available(profile, region, instance_id):
    session = boto3.Session(profile_name=profile, region_name=region)
    ssm = session.client("ssm")
    try:
        resp = ssm.describe_instance_information(Filters=[{"Key": "InstanceIds", "Values": [instance_id]}])
        info = resp.get("InstanceInformationList", [])
        return bool(info and info[0].get("PingStatus") == "Online")
    except Exception:
        return False


def run_ssm_command(profile, region, instance_id, script, timeout=60):
    session = boto3.Session(profile_name=profile, region_name=region)
    ssm = session.client("ssm")
    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id], DocumentName="AWS-RunPowerShellScript",
            Parameters={"commands": [script]}, TimeoutSeconds=timeout,
        )
    except Exception as e:
        return "", f"ERROR: {e}"
    cmd_id = resp["Command"]["CommandId"]
    for _ in range(30):
        time.sleep(2)
        try:
            inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
            if inv["Status"] in ("Success", "Failed", "TimedOut", "Cancelled"):
                return inv.get("StandardOutputContent", "").strip(), inv["Status"]
        except Exception:
            continue
    return "", "TimedOut"


def get_current_disk_usage(profile, region, instance_id, drive_letter):
    script = GET_DISK_USAGE_SCRIPT.format(drive_letter=drive_letter)
    stdout, status = run_ssm_command(profile, region, instance_id, script)
    if status == "Success":
        for line in stdout.split("\n"):
            if line.startswith("USAGE|"):
                parts = line.split("|")
                if len(parts) == 5:
                    return {"Used": float(parts[2]), "Free": float(parts[3]), "Total": float(parts[4])}
    return None


def get_os_drives(profile, region, instance_id):
    stdout, status = run_ssm_command(profile, region, instance_id, GET_DRIVES_SCRIPT)
    if status != "Success":
        return []
    drives = []
    for line in stdout.strip().split("\n"):
        parts = line.strip().split("|")
        if len(parts) == 4:
            drives.append({"DriveLetter": parts[0], "DiskNumber": parts[1], "SizeGB": parts[2], "VolumeId": parts[3]})
    return drives


def get_ebs_volumes(profile, region, instance_id):
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    volumes = []
    for res in resp["Reservations"]:
        for inst in res["Instances"]:
            for bdm in inst.get("BlockDeviceMappings", []):
                if "Ebs" in bdm:
                    vol_id = bdm["Ebs"]["VolumeId"]
                    vol_resp = ec2.describe_volumes(VolumeIds=[vol_id])
                    for v in vol_resp["Volumes"]:
                        volumes.append({"VolumeId": vol_id, "Device": bdm["DeviceName"], "SizeGB": v["Size"], "VolumeType": v["VolumeType"]})
    return volumes


def find_ebs_for_drive(drive_letter, os_drives, ebs_volumes):
    for d in os_drives:
        if d["DriveLetter"] == drive_letter and d["VolumeId"]:
            clean_id = re.sub(r'[._].*$', '', d["VolumeId"]).strip() if d["VolumeId"] else ""
            for v in ebs_volumes:
                if v["VolumeId"] == clean_id:
                    return v
    return None


def expand_ebs_volume(profile, region, volume_id, new_size_gb):
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")
    print(f"  Expanding EBS volume {volume_id} to {new_size_gb} GB...", end=" ")
    ec2.modify_volume(VolumeId=volume_id, Size=new_size_gb)
    print("modification requested.")
    print(f"  Waiting for volume modification...", end="", flush=True)
    for _ in range(60):
        time.sleep(5)
        resp = ec2.describe_volumes_modifications(VolumeIds=[volume_id])
        mods = resp.get("VolumesModifications", [])
        if mods and mods[0].get("ModificationState") in ("completed", "optimizing"):
            print(f" {mods[0]['ModificationState']}!")
            return True
        print(".", end="", flush=True)
    print(" TIMEOUT")
    return False


def expand_os_partition(profile, region, instance_id, drive_letter):
    print(f"  Expanding partition {drive_letter}:\\ on the server...", end=" ")
    script = EXPAND_PARTITION_SCRIPT.format(drive_letter=drive_letter)
    stdout, status = run_ssm_command(profile, region, instance_id, script, timeout=120)
    if status != "Success":
        print(f"FAILED ({status})")
        return
    print("OK")
    for line in stdout.split("\n"):
        if line.startswith("RESULT|"):
            parts = line.split("|")
            if len(parts) == 5:
                print(f"\n  Drive {parts[1]}:\\")
                print(f"    Used:  {parts[2]} GB")
                print(f"    Free:  {parts[3]} GB")
                print(f"    Total: {parts[4]} GB")
                return


def generate_rfc(server_name, drive_letter, datacenter, current_cap, current_used, old_used, final_size):
    growth = current_used - old_used
    growth_pct = (growth / old_used * 100) if old_used > 0 else 0
    thirty_pct = current_cap * 0.30
    increase = max(growth, thirty_pct)
    calculated_final = math.ceil((current_cap + increase) / 10) * 10
    if final_size < calculated_final:
        final_size = calculated_final

    rfc = f"""
================================================================================
RFC SUMMARY - Disk Expansion
================================================================================

Datacenter: {datacenter}
Server: {server_name}
Drive: {drive_letter}

Current volume size: {current_cap} GB
Current used space: {current_used} GB
Used space 1 year ago: {old_used} GB

Based on the Server Specs Sheet, the {drive_letter} drive is currently at {current_cap} GB.
Following the confluence page, we are increasing the storage based on the calculated values.

  30% of {current_cap} GB is: {thirty_pct:.1f} GB
  Disk usage growth from {old_used} GB to {current_used} GB in 1 year is: {growth:.1f} GB = {growth_pct:.2f}% growth over the span of 1 year.
  Increased volume size: {final_size} GB (rounded up to the nearest tens position)

================================================================================
"""
    return rfc, final_size


# =============================================================================
# Main
# =============================================================================
def main():
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
            sys.exit(1)
        profile = acct["profile"]
        sso_session = acct["ssoSession"]
        print(f"Account: {acct['name']} ({acct['org']}, {acct['accountId']})")
        ensure_profile_session(profile, sso_session)
    else:
        profiles = load_all_profiles()
        if not profiles:
            print("No profiles found in accounts.json")
            sys.exit(1)

    # 1. Get alert details
    print("How do you want to provide alert details?")
    print("  [1] Enter details manually (Host, Drive, Datacenter)")
    print("  [2] Paste full alert block from LM")
    mode = input("\nSelect (1/2): ").strip()

    if mode == "2":
        alert = parse_pasted_block()
    else:
        alert = parse_alert_input()

    server_name = alert["server_name"]
    drive_letter = alert["drive_letter"]
    datacenter = alert["datacenter"] or "Vegas"

    if not server_name:
        server_name = input("\nServer name: ").strip().split(".")[0]
    if not drive_letter:
        drive_letter = input("Drive letter: ").strip().upper()
    if not datacenter:
        datacenter = input("Datacenter (Vegas/Voorhees): ").strip() or "Vegas"

    print(f"\n  Server: {server_name}")
    print(f"  Drive: {drive_letter}")
    print(f"  Datacenter: {datacenter}")

    # 2. Historical usage
    print("\n--- Historical Data (1 year ago) ---")
    print("Check LM graphs for this server's disk usage 1 year ago.")
    old_used_input = input("Disk Used 1 year ago (GB): ").strip()
    old_used = float(old_used_input) if old_used_input else 0

    # 3. Select AWS OU and find instance
    print("\nOpening AWS OU selector...")
    profile = pick_profile_gui(profiles)
    if not profile:
        sys.exit(0)
    print(f"Selected OU: {profile}")
    ensure_profile_session(profile, get_sso_session_for_profile(profile))

    print(f"\nSearching for '{server_name}'...")
    instances = find_instances(profile, server_name)
    if not instances:
        print("No instances found.")
        sys.exit(1)

    if len(instances) == 1:
        server = instances[0]
        print(f"Found: {server['Name']} ({server['InstanceId']}) - {server['Region']}")
    else:
        print(f"\n{'#':<4} {'Name':<30} {'Instance ID':<22} {'Region'}")
        print("-" * 70)
        for i, inst in enumerate(instances, 1):
            print(f"{i:<4} {inst['Name']:<30} {inst['InstanceId']:<22} {inst['Region']}")
        sel = input("\nSelect server: ").strip()
        server = instances[int(sel) - 1]

    iid = server["InstanceId"]
    region = server["Region"]

    # 4. Check SSM
    print("Checking SSM connectivity...", end=" ")
    if not check_ssm_available(profile, region, iid):
        print("OFFLINE")
        print("  SSM agent not available. Cannot proceed.")
        sys.exit(1)
    print("CONNECTED")

    # 5. Get current disk usage
    print(f"\nFetching current {drive_letter}:\\ usage from server...")
    usage = get_current_disk_usage(profile, region, iid, drive_letter)
    if not usage:
        print("Could not fetch disk usage.")
        sys.exit(1)

    current_cap = usage["Total"]
    current_used = usage["Used"]
    current_free = usage["Free"]
    print(f"  Used: {current_used} GB / Free: {current_free} GB / Total: {current_cap} GB")

    if old_used == 0:
        old_used = round(current_used * 0.7, 2)
        print(f"  (No historical data — estimating 1yr ago usage as {old_used} GB)")

    # 6. Generate RFC
    rfc, final_size = generate_rfc(server["Name"], drive_letter, datacenter, current_cap, current_used, old_used, 0)
    print(rfc)

    # 7. Confirm size
    while True:
        print(f"\nProposed new TOTAL size: {final_size} GB (current: {current_cap} GB)")
        resp = input(f"Type 'yes' to proceed with {final_size} GB, or enter a different TOTAL size in GB (not extra space), or 'no' to cancel: ").strip().lower()
        if resp == "no":
            print("Cancelled. RFC summary above can still be used for your change request.")
            sys.exit(0)
        if resp == "yes":
            break
        if resp.isdigit() and int(resp) > current_cap:
            final_size = int(resp)
            continue
        if resp.isdigit():
            print(f"  Size must be greater than current size ({current_cap} GB). This is the TOTAL disk size, not extra space.")
        else:
            print("  Please type 'yes' to proceed, 'no' to cancel, or enter a valid TOTAL size in GB.")

    # 8. Find EBS volume
    print("\nMapping drive to EBS volume...")
    os_drives = get_os_drives(profile, region, iid)
    ebs_volumes = get_ebs_volumes(profile, region, iid)
    ebs_vol = find_ebs_for_drive(drive_letter, os_drives, ebs_volumes)

    if not ebs_vol:
        print(f"Could not find EBS volume for drive {drive_letter}:\\")
        for d in os_drives:
            print(f"  {d['DriveLetter']}:\\ -> {d['VolumeId']}")
        sys.exit(1)

    print(f"  {drive_letter}:\\ -> {ebs_vol['VolumeId']} (currently {ebs_vol['SizeGB']} GB)")

    # 9. Expand
    expand_ebs_volume(profile, region, ebs_vol["VolumeId"], final_size)
    expand_os_partition(profile, region, iid, drive_letter)

    print("\n=== Disk expansion complete ===")


if __name__ == "__main__":
    main()
