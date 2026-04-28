"""
Foundation Service Restart Tool
Connect to Foundation OU servers via SSM and restart Windows services.

Usage:  python restart_services.py
Requires: pip install boto3
"""

import boto3
import configparser
import json
import os
import re
import subprocess
import sys
import time
import tkinter as tk
from tkinter import ttk

SSO_SESSION = "foundation"
REGIONS = ["us-east-1", "us-west-2"]

# Script templates for SSM
FIND_SERVICES_SCRIPT = r'''
$pattern = "{pattern}"
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
    """Parse ~/.aws/config and return profiles that use the foundation sso_session."""
    config = configparser.ConfigParser()
    config_path = os.path.join(os.path.expanduser("~"), ".aws", "config")
    config.read(config_path)
    profiles = {}
    for section in config.sections():
        if section.startswith("profile "):
            name = section.replace("profile ", "")
            if config.get(section, "sso_session", fallback="") == "foundation":
                profiles[name] = config.get(section, "sso_account_id", fallback="")
    return profiles


def pick_profile_gui(profiles):
    """Show a GUI window with a searchable dropdown to pick an AWS OU profile."""
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

    def update_list(*args):
        query = search_var.get().lower()
        listbox.delete(0, tk.END)
        for p in profile_list:
            if query in p.lower():
                listbox.insert(tk.END, f"{p}  ({profiles[p]})")

    search_var.trace_add("write", update_list)
    update_list()

    def on_select(event=None):
        sel = listbox.curselection()
        if sel:
            text = listbox.get(sel[0])
            selected["profile"] = text.split("  (")[0]
            root.destroy()

    def on_double_click(event):
        on_select()

    def on_enter(event):
        if listbox.curselection():
            on_select()
        elif listbox.size() == 1:
            listbox.selection_set(0)
            on_select()

    listbox.bind("<Double-Button-1>", on_double_click)
    root.bind("<Return>", on_enter)

    btn = tk.Button(root, text="Select", command=on_select, font=("Segoe UI", 10), width=15)
    btn.pack(pady=10)

    root.mainloop()
    return selected["profile"]


def sso_login(profile):
    """Check SSO session; open browser if expired."""
    print(f"Checking SSO session for {profile}...", end=" ")
    try:
        session = boto3.Session(profile_name=profile)
        sts = session.client("sts")
        identity = sts.get_caller_identity()
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


def find_instance(profile, server_name):
    """Find EC2 instance by Name tag across regions."""
    for region in REGIONS:
        print(f"  Searching {region}...", end=" ")
        session = boto3.Session(profile_name=profile, region_name=region)
        ec2 = session.client("ec2")
        resp = ec2.describe_instances(Filters=[
            {"Name": "tag:Name", "Values": [server_name]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ])
        for res in resp["Reservations"]:
            for inst in res["Instances"]:
                iid = inst["InstanceId"]
                print(f"FOUND {iid}")
                return iid, region
        print("not found.")
    return None, None


def check_ssm_online(profile, instance_id, region):
    """Check if SSM agent is online on the instance."""
    session = boto3.Session(profile_name=profile, region_name=region)
    ssm = session.client("ssm")
    try:
        resp = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
        )
        info = resp.get("InstanceInformationList", [])
        if info and info[0].get("PingStatus") == "Online":
            return True
    except Exception:
        pass
    return False


def run_ssm_command(profile, region, instance_id, script, timeout=60):
    """Run a PowerShell script via SSM and return stdout."""
    session = boto3.Session(profile_name=profile, region_name=region)
    ssm = session.client("ssm")
    resp = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunPowerShellScript",
        Parameters={"commands": [script]},
        TimeoutSeconds=timeout,
    )
    cmd_id = resp["Command"]["CommandId"]

    # Wait for completion
    for _ in range(30):
        time.sleep(2)
        try:
            inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
            if inv["Status"] in ("Success", "Failed", "TimedOut", "Cancelled"):
                stdout = inv.get("StandardOutputContent", "")
                stderr = inv.get("StandardErrorContent", "")
                if stderr:
                    print(f"  STDERR: {stderr.strip()}")
                return stdout.strip(), inv["Status"]
        except ssm.exceptions.InvocationDoesNotExist:
            continue
    return "", "TimedOut"


def find_services(profile, region, instance_id, pattern):
    """Find services matching a wildcard pattern."""
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
        status_color = svc["Status"]
        print(f"{i:<4} {svc['ServiceName']:<45} {svc['DisplayName']:<55} {status_color}")


def restart_or_start_services(profile, region, instance_id, services, indices):
    """Restart running services or start stopped ones."""
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

            # Verify
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
    # 1. Load profiles and show GUI picker
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

    # 2. SSO login
    if not sso_login(profile):
        sys.exit(1)

    # 3. Server name
    server_name = input("\nEnter server name (e.g. REDB-PTRKWB001): ").strip()
    if not server_name:
        print("Server name required.")
        sys.exit(1)

    # 4. Find instance
    print(f"\nLooking up '{server_name}'...")
    instance_id, region = find_instance(profile, server_name)
    if not instance_id:
        print(f"Server '{server_name}' not found in any region.")
        sys.exit(1)

    # 5. Check SSM connectivity
    print(f"Checking SSM connectivity...", end=" ")
    if check_ssm_online(profile, instance_id, region):
        print("CONNECTED")
    else:
        print("OFFLINE - SSM agent not reachable.")
        sys.exit(1)

    # 6. Service loop
    while True:
        pattern = input("\nEnter service name wildcard (e.g. *Superion* or *Trakit*): ").strip()
        if not pattern:
            print("Pattern required.")
            continue

        print(f"Searching for services matching '{pattern}'...")
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

    print("\n=== Session complete ===")


if __name__ == "__main__":
    main()
