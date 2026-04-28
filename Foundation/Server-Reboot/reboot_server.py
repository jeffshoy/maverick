"""
Foundation Server Reboot Tool
Find EC2 instances by client/server code, show health status, reboot, and wait for online.

Usage:  python reboot_server.py
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
        for page in pages:
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

        # Fetch status checks
        if instance_ids:
            try:
                status_resp = ec2.describe_instance_status(
                    InstanceIds=instance_ids, IncludeAllInstances=True
                )
                for s in status_resp.get("InstanceStatuses", []):
                    iid = s["InstanceId"]
                    sys_status = s.get("SystemStatus", {}).get("Status", "N/A")
                    inst_status = s.get("InstanceStatus", {}).get("Status", "N/A")
                    sys_details = s.get("SystemStatus", {}).get("Details", [])
                    inst_details = s.get("InstanceStatus", {}).get("Details", [])
                    passed = sum(1 for d in sys_details + inst_details if d.get("Status") == "passed")
                    total = len(sys_details) + len(inst_details)
                    health = f"{passed}/{total} ({sys_status}/{inst_status})" if total > 0 else f"{sys_status}/{inst_status}"
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
    print(f"\n{'Instance ID':<22} {'System Status':<15} {'Instance Status'}")
    print("-" * 55)
    for s in resp.get("InstanceStatuses", []):
        sys_s = s.get("SystemStatus", {}).get("Status", "N/A")
        inst_s = s.get("InstanceStatus", {}).get("Status", "N/A")
        print(f"{s['InstanceId']:<22} {sys_s:<15} {inst_s}")


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
                if not sso_login(profile):
                    sys.exit(1)
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
            if not sso_login(profile):
                sys.exit(1)
            continue
        else:
            break

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
