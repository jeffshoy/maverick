"""
Foundation Disk Expand (LogicMonitor Integration)
Pulls disk alerts from LM, compares historical vs current usage, generates RFC summary,
and expands EBS + OS partition on confirmation.

Usage:  python expand_disk_lm.py
Requires: pip install boto3 requests python-dotenv
"""

import boto3
import configparser
import hashlib
import hmac
import json
import math
import os
import subprocess
import sys
import time
import tkinter as tk

try:
    import requests
    from dotenv import load_dotenv
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
except ImportError:
    print("Missing dependencies. Run: pip install requests python-dotenv")
    sys.exit(1)

# Load .env from script directory
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

LM_PORTAL = os.getenv("LM_PORTAL", "superion.logicmonitor.com")
LM_ACCESS_ID = os.getenv("LM_ACCESS_ID", "")
LM_ACCESS_KEY = os.getenv("LM_ACCESS_KEY", "")
SSO_SESSION = "foundation"
REGIONS = ["us-east-1", "us-west-2"]

# SSM scripts
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
# LogicMonitor API
# =============================================================================
def lm_request(method, resource_path, params=None):
    """Make an authenticated LMv1 API request."""
    import base64
    url = f"https://{LM_PORTAL}/santaba/rest{resource_path}"
    epoch = str(int(time.time() * 1000))
    request_vars = method.upper() + epoch + resource_path
    sig_hash = hmac.new(
        LM_ACCESS_KEY.encode("utf-8"),
        msg=request_vars.encode("utf-8"),
        digestmod=hashlib.sha256
    ).digest()
    sig_b64 = base64.b64encode(sig_hash).decode("utf-8")
    auth = f"LMv1 {LM_ACCESS_ID}:{sig_b64}:{epoch}"
    headers = {"Authorization": auth, "Content-Type": "application/json", "X-Version": "3"}
    resp = requests.get(url, headers=headers, params=params or {}, timeout=30, verify=False)
    resp.raise_for_status()
    return resp.json()


def fetch_disk_alerts(limit=20):
    """Fetch recent disk-related alerts from LogicMonitor."""
    params = {
        "size": limit,
        "sort": "-startEpoch",
        "filter": "dataPointName~\"Capacity\"|dataPointName~\"PercentUsed\"|dataPointName~\"FreeSpace\"|dataPointName~\"UsedSpace\"|dataPointName~\"percentUsed\"|datasourceName~\"Volume\"",
    }
    data = lm_request("GET", "/alert/alerts", params)
    alerts = data.get("data", {}).get("items", [])
    return alerts


def fetch_device_data(device_id, datasource_filter="Volume"):
    """Fetch datasource instances for a device to get disk usage data."""
    params = {"size": 100, "filter": f"dataSourceDisplayName~\"{datasource_filter}\""}
    data = lm_request("GET", f"/device/devices/{device_id}/devicedatasources", params)
    return data.get("data", {}).get("items", [])


def fetch_instance_data(device_id, ds_id):
    """Fetch instances for a device datasource."""
    data = lm_request("GET", f"/device/devices/{device_id}/devicedatasources/{ds_id}/instances")
    return data.get("data", {}).get("items", [])


def fetch_graph_data(device_id, ds_id, instance_id, datapoint="PercentUsed", period="-365d"):
    """Fetch historical data for a datapoint."""
    end_time = int(time.time())
    start_time = end_time - (365 * 24 * 3600)  # 1 year ago
    params = {"start": start_time, "end": end_time, "datapoints": datapoint}
    try:
        data = lm_request("GET", f"/device/devices/{device_id}/devicedatasources/{ds_id}/instances/{instance_id}/data", params)
        return data.get("data", {})
    except Exception:
        return {}


def display_alerts(alerts):
    print(f"\n{'#':<4} {'Server':<35} {'Datasource':<35} {'Datapoint':<20} {'Value':<10} {'Started'}")
    print("-" * 130)
    for i, a in enumerate(alerts, 1):
        host = a.get("monitorObjectName", "N/A")
        ds = a.get("resourceTemplateName", a.get("datasourceName", "N/A"))
        dp = a.get("dataPointName", "N/A")
        val = a.get("alertValue", "N/A")
        start = time.strftime("%Y-%m-%d %H:%M", time.localtime(a.get("startEpoch", 0)))
        print(f"{i:<4} {host:<35} {ds:<35} {dp:<20} {val:<10} {start}")


def parse_drive_from_alert(alert):
    """Try to extract drive letter from alert datasource/instance name."""
    instance_name = alert.get("instanceName", "")
    # Common patterns: "C:\", "WinVolumeUsage-C:", "Volume-C"
    for char in instance_name:
        if char.isalpha() and char.upper() in "CDEFGHIJKLMNOPQRSTUVWXYZ":
            return char.upper()
    ds_name = alert.get("resourceTemplateName", "") + alert.get("datasourceName", "")
    for part in ds_name.replace("-", " ").replace("_", " ").split():
        if len(part) == 1 and part.upper() in "CDEFGHIJKLMNOPQRSTUVWXYZ":
            return part.upper()
    return None


def parse_server_from_alert(alert):
    """Extract server hostname from alert."""
    host = alert.get("monitorObjectName", "")
    # Strip domain suffix if present
    return host.split(".")[0] if host else None


# =============================================================================
# AWS / SSM helpers (same as expand_disk.py)
# =============================================================================
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
    """Get current disk usage from the server via SSM."""
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
    """Match a drive letter to its EBS volume."""
    for d in os_drives:
        if d["DriveLetter"] == drive_letter and d["VolumeId"]:
            for v in ebs_volumes:
                if v["VolumeId"] == d["VolumeId"]:
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
    """Generate RFC summary matching the Disk Capacity Planner format."""
    growth = current_used - old_used
    growth_pct = (growth / old_used * 100) if old_used > 0 else 0
    thirty_pct = current_cap * 0.30
    increase = max(growth, thirty_pct)
    calculated_final = math.ceil((current_cap + increase) / 10) * 10

    # Use the larger of calculated or user-specified
    if final_size < calculated_final:
        final_size = calculated_final

    rfc = f"""
================================================================================
RFC SUMMARY — Disk Expansion
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
    if not LM_ACCESS_ID or not LM_ACCESS_KEY:
        print("LM credentials not found. Set LM_ACCESS_ID and LM_ACCESS_KEY in .env file.")
        print(f"Expected .env location: {os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')}")
        sys.exit(1)

    profiles = load_foundation_profiles()
    if not profiles:
        print("No foundation profiles found in ~/.aws/config")
        sys.exit(1)

    # 1. Fetch LM alerts
    print("Fetching disk alerts from LogicMonitor...")
    try:
        alerts = fetch_disk_alerts()
    except Exception as e:
        print(f"Failed to fetch LM alerts: {e}")
        print("\nFalling back to manual mode...")
        alerts = []

    if alerts:
        display_alerts(alerts)
        sel = input("\nSelect alert by number (or press Enter to enter details manually): ").strip()

        if sel.isdigit() and 1 <= int(sel) <= len(alerts):
            alert = alerts[int(sel) - 1]
            server_name = parse_server_from_alert(alert)
            drive_letter = parse_drive_from_alert(alert)
            datacenter = "Vegas" if "Vegas" in alert.get("monitorObjectGroups", [{}])[0].get("name", "") else "Voorhees"

            print(f"\nFrom alert:")
            print(f"  Server: {server_name}")
            print(f"  Drive: {drive_letter or '(could not detect)'}")
            print(f"  Datacenter: {datacenter}")

            if not drive_letter:
                drive_letter = input("  Enter drive letter: ").strip().upper()
            confirm = input("\nCorrect? (Y/N): ").strip().lower()
            if confirm != "y":
                server_name = input("Server name: ").strip()
                drive_letter = input("Drive letter: ").strip().upper()
                datacenter = input("Datacenter (Vegas/Voorhees): ").strip()
        else:
            server_name = None
    else:
        server_name = None

    # Manual entry if no alert selected
    if not server_name:
        server_name = input("\nEnter server name (e.g. REDB-PTRKWB001): ").strip()
        drive_letter = input("Enter drive letter (e.g. C): ").strip().upper()
        datacenter = input("Datacenter (Vegas/Voorhees): ").strip()

    if not server_name or not drive_letter:
        print("Server name and drive letter are required.")
        sys.exit(1)

    # 2. Ask for 1-year-ago usage (from LM or manual)
    print("\n--- Historical Data (1 year ago) ---")
    old_used_input = input("Disk Used 1 year ago (GB) — check LM graphs or enter manually: ").strip()
    old_used = float(old_used_input) if old_used_input else 0

    # 3. Select AWS OU and find instance
    print("\nOpening AWS OU selector...")
    profile = pick_profile_gui(profiles)
    if not profile:
        sys.exit(0)
    print(f"Selected OU: {profile}")
    if not sso_login(profile):
        sys.exit(1)

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

    # 5. Get current disk usage from server
    print(f"\nFetching current {drive_letter}:\\ usage from server...")
    usage = get_current_disk_usage(profile, region, iid, drive_letter)
    if not usage:
        print("Could not fetch disk usage.")
        sys.exit(1)

    current_cap = usage["Total"]
    current_used = usage["Used"]
    current_free = usage["Free"]

    print(f"  Current: {current_used} GB used / {current_free} GB free / {current_cap} GB total")

    if old_used == 0:
        old_used = current_used * 0.7  # Estimate if not provided
        print(f"  (No historical data — estimating 1yr ago usage as {old_used:.1f} GB)")

    # 6. Generate RFC
    rfc, final_size = generate_rfc(
        server_name=server["Name"],
        drive_letter=drive_letter,
        datacenter=datacenter,
        current_cap=current_cap,
        current_used=current_used,
        old_used=old_used,
        final_size=0,
    )

    print(rfc)

    # 7. Confirm and expand
    print(f"Proposed new size: {final_size} GB (current: {current_cap} GB)")
    override = input(f"Accept {final_size} GB or enter a different size (press Enter to accept): ").strip()
    if override.isdigit():
        final_size = int(override)
        if final_size <= current_cap:
            print(f"Must be greater than {current_cap} GB.")
            sys.exit(1)

    confirm = input(f"\nProceed with expanding {drive_letter}:\\ to {final_size} GB? (Y/N): ").strip().lower()
    if confirm != "y":
        print("Cancelled. RFC summary above can still be used.")
        sys.exit(0)

    # 8. Find EBS volume for this drive
    print("\nMapping drive to EBS volume...")
    os_drives = get_os_drives(profile, region, iid)
    ebs_volumes = get_ebs_volumes(profile, region, iid)
    ebs_vol = find_ebs_for_drive(drive_letter, os_drives, ebs_volumes)

    if not ebs_vol:
        print(f"Could not find EBS volume for drive {drive_letter}:\\")
        print("Available mappings:")
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
