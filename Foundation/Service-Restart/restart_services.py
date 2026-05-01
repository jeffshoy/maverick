"""
Foundation Service Restart Tool
Connect to Foundation OU servers via SSM and restart Windows services.

Usage:  python restart_services.py
Requires: pip install boto3
"""

import boto3
import configparser
import os
import subprocess
import sys
import time
import tkinter as tk

SSO_SESSION = "foundation"
REGIONS = ["us-east-1", "us-west-2"]

FIND_SERVICES_SCRIPT = r'''
$pattern = "*{pattern}*"
$services = Get-Service | Where-Object {{ $_.DisplayName -like $pattern -or $_.ServiceName -like $pattern }}
if ($services) {{
    $services | ForEach-Object {{
        Write-Output "$($_.ServiceName)|$($_.DisplayName)|$($_.Status)"
    }}
}} else {{
    Write-Output "NO_SERVICES_FOUND"
}}
'''

RESTART_SERVICE_SCRIPT = r'''
$svcName = "{service_name}"
$svc = Get-Service -Name $svcName
if ($svc.Status -eq "Running") {{
    Restart-Service -Name $svcName -Force
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name $svcName
    Write-Output "RESTARTED|$($svc.ServiceName)|$($svc.Status)"
}} else {{
    Start-Service -Name $svcName
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name $svcName
    Write-Output "STARTED|$($svc.ServiceName)|$($svc.Status)"
}}
'''

CHECK_SERVICE_SCRIPT = r'''
$svcName = "{service_name}"
$svc = Get-Service -Name $svcName
Write-Output "$($svc.ServiceName)|$($svc.DisplayName)|$($svc.Status)"
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
    search_entry = tk.Entry(root, textvariable=search_var, font=("Segoe UI", 10), width=50)
    search_entry.pack(pady=5)
    search_entry.focus_set()

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
            if not sso_login(profile):
                sys.exit(1)
            continue
        else:
            break

    print("\n=== Session complete ===")


if __name__ == "__main__":
    main()
