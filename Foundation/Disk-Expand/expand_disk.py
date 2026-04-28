"""
Foundation Disk Expand Tool
Expand EBS volumes and resize OS partitions on Foundation OU servers via SSM.

Usage:  python expand_disk.py
Requires: pip install boto3
"""

import boto3
import configparser
import math
import os
import subprocess
import sys
import time
import tkinter as tk

SSO_SESSION = "foundation"
REGIONS = ["us-east-1", "us-west-2"]

# SSM script to get drive letters and their sizes from inside the server
GET_DRIVES_SCRIPT = r'''
Get-Partition | Where-Object { $_.DriveLetter -ne "`0" } | ForEach-Object {
    $letter = $_.DriveLetter
    $diskNum = $_.DiskNumber
    $sizeGB = [Math]::Round($_.Size / 1GB, 2)
    $disk = Get-Disk -Number $diskNum
    $serialRaw = $disk.SerialNumber
    # AWS EBS volume IDs appear as vol0abc123 in serial, convert to vol-0abc123
    $volId = ""
    if ($serialRaw -match "^vol") {
        $volId = $serialRaw -replace "^vol", "vol-"
        $volId = $volId.Trim()
    }
    Write-Output "$letter|$diskNum|$sizeGB|$volId"
}
'''

# SSM script to expand partition after EBS resize
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


def load_foundation_profiles():
    config = configparser.ConfigParser()
    config.read(os.path.join(os.path.expanduser("~"), ".aws", "config"))
    profiles = {}
    for section in config.sections():
        if section.startswith("profile "):
            name = section.replace("profile ", "")
            if config.get(section, "sso_session", fallback="") == "foundation":
                profiles[name] = config.get(section, "sso_account_id", fallback="")
    return profiles


def pick_profile_gui(profiles):
    selected = {"profile": None}
    root = tk.Tk()
    root.title("Select AWS OU")
    root.geometry("500x400")
    root.resizable(False, False)

    tk.Label(root, text="Search and select AWS OU:", font=("Segoe UI", 11)).pack(pady=(15, 5))
    search_var = tk.StringVar()
    tk.Entry(root, textvariable=search_var, font=("Segoe UI", 10), width=50).pack(pady=5)

    frame = tk.Frame(root)
    frame.pack(fill=tk.BOTH, expand=True, padx=20, pady=5)
    scrollbar = tk.Scrollbar(frame)
    scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
    listbox = tk.Listbox(frame, font=("Consolas", 10), yscrollcommand=scrollbar.set, width=60)
    listbox.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
    scrollbar.config(command=listbox.yview)

    profile_list = sorted(profiles.keys())

    def update_list(*_):
        q = search_var.get().lower()
        listbox.delete(0, tk.END)
        for p in profile_list:
            if q in p.lower():
                listbox.insert(tk.END, f"{p}  ({profiles[p]})")

    search_var.trace_add("write", update_list)
    update_list()

    def on_select(event=None):
        sel = listbox.curselection()
        if sel:
            selected["profile"] = listbox.get(sel[0]).split("  (")[0]
            root.destroy()

    listbox.bind("<Double-Button-1>", lambda e: on_select())
    root.bind("<Return>", lambda e: on_select() if listbox.curselection() else None)
    tk.Button(root, text="Select", command=on_select, font=("Segoe UI", 10), width=15).pack(pady=10)
    root.mainloop()
    return selected["profile"]


def sso_login(profile):
    print(f"Checking SSO session for {profile}...", end=" ")
    try:
        session = boto3.Session(profile_name=profile)
        identity = session.client("sts").get_caller_identity()
        print(f"OK - {identity['Arn']}")
        return True
    except Exception:
        print("expired.")
        print("Opening browser for SSO login...")
        ret = subprocess.run(["aws", "sso", "login", "--sso-session", SSO_SESSION])
        if ret.returncode != 0:
            print("SSO login failed.")
            return False
        print("SSO login successful.")
        return True


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


def run_ssm_command(profile, region, instance_id, script, timeout=60):
    session = boto3.Session(profile_name=profile, region_name=region)
    ssm = session.client("ssm")
    resp = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunPowerShellScript",
        Parameters={"commands": [script]},
        TimeoutSeconds=timeout,
    )
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
    # Match EBS volumes to OS drives by volume ID
    drive_map = {}
    for d in os_drives:
        if d["VolumeId"]:
            drive_map[d["VolumeId"]] = d

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
    profiles = load_foundation_profiles()
    if not profiles:
        print("No foundation profiles found in ~/.aws/config")
        sys.exit(1)

    print(f"Found {len(profiles)} profiles. Opening selector...")
    profile = pick_profile_gui(profiles)
    if not profile:
        print("No profile selected. Exiting.")
        sys.exit(0)
    print(f"\nSelected OU: {profile}")

    if not sso_login(profile):
        sys.exit(1)

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
                if not sso_login(profile):
                    sys.exit(1)
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

        # 2. Get EBS volumes + OS drives
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

        # 4. Ask for new size
        while True:
            new_size_input = input(f"\nEnter new total size in GB (must be > {current_size}): ").strip()
            if not new_size_input.isdigit():
                print("Enter a number.")
                continue
            new_size = int(new_size_input)
            if new_size <= current_size:
                print(f"Must be greater than current size ({current_size} GB). Try again.")
                continue
            break

        print(f"\nExpanding {drive['DriveLetter']}:\\ from {current_size} GB to {new_size} GB...")

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
                new_size_input = input(f"\nEnter new total size in GB (must be > {current_size}): ").strip()
                if not new_size_input.isdigit():
                    print("Enter a number.")
                    continue
                new_size = int(new_size_input)
                if new_size <= current_size:
                    print(f"Must be greater than current size ({current_size} GB). Try again.")
                    continue
                break
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
            if not sso_login(profile):
                sys.exit(1)
            continue
        else:
            break

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
