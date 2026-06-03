"""
Foundation Site Monitor Investigation Tool
Parses LM site monitor alerts, investigates IIS status and event logs via SSM,
highlights critical findings, and offers remediation actions.

Usage:  python investigate.py
Requires: pip install boto3 colorama
"""

import argparse
import os
import re
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

try:
    from colorama import init, Fore, Back, Style
    init()
    HIGHLIGHT = Back.LIGHTRED_EX + Fore.BLACK
    RESET = Style.RESET_ALL
    YELLOW = Fore.YELLOW
    GREEN = Fore.GREEN
    RED = Fore.RED
    CYAN = Fore.CYAN
except ImportError:
    print("colorama not found. Install with: pip install colorama")
    print("Continuing without color highlighting.\n")
    HIGHLIGHT = RESET = YELLOW = GREEN = RED = CYAN = ""

REGIONS = ["us-east-1", "us-west-2", "ca-central-1"]

# ---------------------------------------------------------------------------
# PowerShell scripts to run via SSM
# ---------------------------------------------------------------------------
IIS_STATUS_SCRIPT = r'''
Import-Module WebAdministration -ErrorAction SilentlyContinue

Write-Output "===APP_POOLS==="
Get-ChildItem IIS:\AppPools | ForEach-Object {
    $name = $_.Name
    $state = $_.State
    Write-Output "$name|$state"
}

Write-Output "===SITES==="
Get-ChildItem IIS:\Sites | ForEach-Object {
    $name = $_.Name
    $state = $_.State
    $bindings = ($_.Bindings.Collection | ForEach-Object { $_.bindingInformation }) -join "; "
    Write-Output "$name|$state|$bindings"
}
'''

EVENT_LOG_SCRIPT = r'''
$cutoff = (Get-Date).AddHours(-6)
$logs = @("Application", "System")
foreach ($logName in $logs) {
    Write-Output "===LOG_$logName==="
    Get-WinEvent -FilterHashtable @{LogName=$logName; Level=1,2,3; StartTime=$cutoff} -MaxEvents 30 -ErrorAction SilentlyContinue |
        ForEach-Object {
            $time = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
            $level = $_.LevelDisplayName
            $source = $_.ProviderName
            $id = $_.Id
            $msg = ($_.Message -replace "`r`n|`n", " ").Substring(0, [Math]::Min($_.Message.Length, 200))
            Write-Output "$time|$level|$source|$id|$msg"
        }
}
'''

RESTART_APPPOOL_SCRIPT = r'''
Import-Module WebAdministration -ErrorAction SilentlyContinue
$pool = '{pool_name}'
if ((Get-WebAppPoolState -Name $pool).Value -ne 'Started') {{
    Start-WebAppPool -Name $pool
    Write-Output "STARTED|$pool"
}} else {{
    Restart-WebAppPool -Name $pool
    Write-Output "RESTARTED|$pool"
}}
Start-Sleep -Seconds 2
$state = (Get-WebAppPoolState -Name $pool).Value
Write-Output "STATUS|$pool|$state"
'''

RESTART_IIS_SCRIPT = r'''
iisreset /restart
Start-Sleep -Seconds 5
Import-Module WebAdministration -ErrorAction SilentlyContinue
Write-Output "===APP_POOLS==="
Get-ChildItem IIS:\AppPools | ForEach-Object {
    Write-Output "$($_.Name)|$($_.State)"
}
Write-Output "===SITES==="
Get-ChildItem IIS:\Sites | ForEach-Object {
    Write-Output "$($_.Name)|$($_.State)"
}
'''

REBOOT_SCRIPT = r'''
Write-Output "REBOOTING"
Restart-Computer -Force
'''


# ---------------------------------------------------------------------------
# Alert parsing
# ---------------------------------------------------------------------------
def parse_alert():
    print("\n=== Paste Alert Block ===")
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
        "client_code": None,
        "service_url": None,
        "service_group": None,
        "datacenter": None,
        "value": None,
        "start": None,
    }

    # Service URL
    url_match = re.search(r"Service URL[:\s]+(https?://\S+)", text, re.IGNORECASE)
    if url_match:
        result["service_url"] = url_match.group(1)

    # Service Group
    sg_match = re.search(r"Service Group[:\s]+(.*)", text, re.IGNORECASE)
    if sg_match:
        result["service_group"] = sg_match.group(1).strip()
        group_text = result["service_group"].lower()
        if "voorhees" in group_text:
            result["datacenter"] = "Voorhees"
        elif "vegas" in group_text:
            result["datacenter"] = "Vegas"

    # Value
    val_match = re.search(r"Value[:\s]+(.*)", text, re.IGNORECASE)
    if val_match:
        result["value"] = val_match.group(1).strip()

    # Start
    start_match = re.search(r"Start[:\s]+(.*)", text, re.IGNORECASE)
    if start_match:
        result["start"] = start_match.group(1).strip()

    # Extract client code from Service URL or Service Group
    # URL pattern: https://auro-trk.aspgov.com/... -> AURO
    if result["service_url"]:
        url_code = re.search(r"https?://([a-zA-Z]+)", result["service_url"])
        if url_code:
            result["client_code"] = url_code.group(1).upper()

    # Fallback: from Service Group path like .../External AURO Community Development
    if not result["client_code"] and result["service_group"]:
        # Look for pattern: External <CODE> or just grab capitalized words
        sg_code = re.search(r"External\s+(\w+)", result["service_group"], re.IGNORECASE)
        if sg_code:
            result["client_code"] = sg_code.group(1).upper()

    return result


# ---------------------------------------------------------------------------
# AWS helpers — delegated to aws_sso_helper
# ---------------------------------------------------------------------------


def find_instances(profile, search_code):
    all_instances = []
    search_lower = search_code.lower()
    for region in REGIONS:
        print(f"  Searching {region}...", end=" ")
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
        count = sum(1 for i in all_instances if i["Region"] == region)
        print(f"{count} found.")
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


# ---------------------------------------------------------------------------
# Investigation & display
# ---------------------------------------------------------------------------
def investigate_iis(profile, region, instance_id):
    print("\n  Checking IIS status...", end=" ", flush=True)
    stdout, status = run_ssm_command(profile, region, instance_id, IIS_STATUS_SCRIPT)
    if status != "Success":
        print(f"FAILED ({status})")
        return [], []

    print("OK")
    app_pools = []
    sites = []
    section = None
    for line in stdout.split("\n"):
        line = line.strip()
        if line == "===APP_POOLS===":
            section = "pools"
            continue
        elif line == "===SITES===":
            section = "sites"
            continue
        if not line:
            continue
        parts = line.split("|")
        if section == "pools" and len(parts) == 2:
            app_pools.append({"Name": parts[0], "State": parts[1].strip()})
        elif section == "sites" and len(parts) >= 2:
            state = parts[1].strip()
            sites.append({"Name": parts[0], "State": state if state else "Started", "Bindings": parts[2] if len(parts) > 2 else ""})

    return app_pools, sites


def investigate_events(profile, region, instance_id):
    print("  Checking event logs (last 6 hours)...", end=" ", flush=True)
    stdout, status = run_ssm_command(profile, region, instance_id, EVENT_LOG_SCRIPT, timeout=90)
    if status != "Success":
        print(f"FAILED ({status})")
        return {}

    print("OK")
    logs = {}
    current_log = None
    for line in stdout.split("\n"):
        line = line.strip()
        if line.startswith("===LOG_") and line.endswith("==="):
            current_log = line.replace("===LOG_", "").replace("===", "")
            logs[current_log] = []
            continue
        if not line or not current_log:
            continue
        parts = line.split("|", 4)
        if len(parts) == 5:
            logs[current_log].append({
                "Time": parts[0], "Level": parts[1],
                "Source": parts[2], "EventId": parts[3], "Message": parts[4],
            })
    return logs


def display_findings(app_pools, sites, event_logs, service_url):
    issues_found = []

    # --- IIS App Pools ---
    print(f"\n{'='*80}")
    print(f"  IIS APPLICATION POOLS")
    print(f"{'='*80}")
    if app_pools:
        print(f"  {'Name':<40} {'State':<15}")
        print(f"  {'-'*55}")
        for pool in app_pools:
            state = pool["State"]
            if state != "Started":
                print(f"  {HIGHLIGHT}{pool['Name']:<40} {state:<15}{RESET}")
                issues_found.append(f"App Pool '{pool['Name']}' is {state}")
            else:
                print(f"  {pool['Name']:<40} {GREEN}{state}{RESET}")
    else:
        print(f"  {YELLOW}No app pools found (IIS may not be installed){RESET}")

    # --- IIS Sites ---
    print(f"\n{'='*80}")
    print(f"  IIS SITES")
    print(f"{'='*80}")
    if sites:
        print(f"  {'Name':<35} {'State':<12} {'Bindings'}")
        print(f"  {'-'*70}")
        for site in sites:
            state = site["State"]
            if state not in ("Started", ""):
                print(f"  {HIGHLIGHT}{site['Name']:<35} {state:<12} {site['Bindings']}{RESET}")
                issues_found.append(f"Site '{site['Name']}' is {state}")
            else:
                print(f"  {site['Name']:<35} {GREEN}{state}{RESET}  {site['Bindings']}")
    else:
        print(f"  {YELLOW}No sites found{RESET}")

    # --- Event Logs ---
    db_keywords = ["sql", "database", "connection string", "login failed", "timeout expired",
                    "cannot open database", "oledb", "odbc", "sqlclient", "db connection"]
    iis_keywords = ["w3svc", "was ", "application pool", "iis", "http.sys", "asp.net",
                     "worker process", "w3wp"]
    # Sources to ignore — noisy and not actionable
    ignore_sources = ["vmstatsprovider"]

    for log_name, entries in event_logs.items():
        print(f"\n{'='*80}")
        print(f"  EVENT LOG: {log_name.upper()} (last 6 hours)")
        print(f"{'='*80}")
        if not entries:
            print(f"  {GREEN}No errors or warnings found{RESET}")
            continue
        print(f"  {'Time':<22} {'Level':<10} {'Source':<25} {'ID':<8} Message")
        print(f"  {'-'*100}")
        # Deduplicate: group by Source+EventId, show count
        seen = {}
        for e in entries:
            key = f"{e['Source']}|{e['EventId']}"
            if key not in seen:
                seen[key] = {"entry": e, "count": 1}
            else:
                seen[key]["count"] += 1

        for key, data in seen.items():
            e = data["entry"]
            count = data["count"]
            source_lower = e["Source"].lower()

            # Skip noisy/irrelevant sources
            if source_lower in ignore_sources:
                continue

            msg_lower = e["Message"].lower()
            is_critical = e["Level"] in ("Critical", "Error")
            is_db = any(kw in msg_lower for kw in db_keywords)
            is_iis = any(kw in msg_lower for kw in iis_keywords)
            count_str = f" (x{count})" if count > 1 else ""

            if is_db:
                prefix = f"{HIGHLIGHT}[DB] "
                suffix = RESET
                issues_found.append(f"[DB] {e['Source']} (ID:{e['EventId']}){count_str}: {e['Message'][:80]}")
            elif is_iis:
                prefix = f"{HIGHLIGHT}[IIS] "
                suffix = RESET
                issues_found.append(f"[IIS] {e['Source']} (ID:{e['EventId']}){count_str}: {e['Message'][:80]}")
            elif is_critical:
                prefix = f"{HIGHLIGHT}"
                suffix = RESET
                issues_found.append(f"{e['Source']} (ID:{e['EventId']}){count_str}: {e['Message'][:80]}")
            else:
                prefix = f"  "
                suffix = ""

            msg_display = e["Message"][:90]
            print(f"{prefix}  {e['Time']:<22} {e['Level']:<10} {e['Source']:<25} {e['EventId']:<8} {msg_display}{count_str}{suffix}")

    # --- Summary ---
    print(f"\n{'='*80}")
    print(f"  INVESTIGATION SUMMARY")
    print(f"{'='*80}")
    if service_url:
        print(f"  Alert URL: {service_url}")

    has_stopped_pools = any(p["State"] != "Started" for p in app_pools)
    has_stopped_sites = any(s["State"].strip() not in ("Started", "") for s in sites) if sites else False
    has_db_issues = any("[DB]" in i for i in issues_found)
    has_iis_issues = any("[IIS]" in i for i in issues_found) or has_stopped_pools or has_stopped_sites

    if not issues_found and not has_stopped_pools and not has_stopped_sites:
        print(f"\n  {GREEN}No obvious issues found. IIS is running and no critical events detected.{RESET}")
    else:
        print(f"\n  {HIGHLIGHT} {len(issues_found)} issue(s) detected: {RESET}\n")
        for i, issue in enumerate(issues_found, 1):
            print(f"  {RED}{i}. {issue}{RESET}")

    if has_db_issues:
        print(f"\n  {HIGHLIGHT} Possible database connectivity issue detected in event logs. {RESET}")
        print(f"  {YELLOW}  Check DB server status, connection strings, and SQL service.{RESET}")

    if has_iis_issues:
        print(f"\n  {HIGHLIGHT} IIS issues detected — app pools or sites may need restart. {RESET}")

    return issues_found, has_stopped_pools, has_stopped_sites, has_db_issues


def offer_actions(profile, region, instance_id, server_name, app_pools, has_stopped_pools, has_db_issues):
    while True:
        print(f"\n{'='*80}")
        print(f"  REMEDIATION OPTIONS")
        print(f"{'='*80}")

        stopped_pools = [p for p in app_pools if p["State"] != "Started"]

        options = []
        if stopped_pools:
            for p in stopped_pools:
                options.append(("pool", p["Name"], f"Start app pool: {p['Name']}"))
        options.append(("iis", None, "Restart IIS (iisreset) — restarts all sites and app pools"))
        options.append(("reboot", None, f"Reboot server {server_name}"))
        options.append(("reinvestigate", None, "Re-run investigation (refresh IIS & event logs)"))
        options.append(("exit", None, "Exit"))

        for i, (_, _, desc) in enumerate(options, 1):
            print(f"  [{i}] {desc}")

        while True:
            choice = input("\nSelect action: ").strip()
            if not choice.isdigit() or int(choice) < 1 or int(choice) > len(options):
                print("  Please enter a valid option number.")
                continue
            break

        action, target, desc = options[int(choice) - 1]

        if action == "exit":
            print("\n  No further action taken.")
            return

        if action == "reinvestigate":
            print(f"\n  Re-running investigation on {server_name}...")
            new_pools, new_sites = investigate_iis(profile, region, instance_id)
            new_logs = investigate_events(profile, region, instance_id)
            display_findings(new_pools, new_sites, new_logs, None)
            app_pools = new_pools
            continue

        # Confirm
        confirmed = False
        while True:
            resp = input(f"\n  Type 'yes' to confirm: {desc}, or 'no' to cancel: ").strip().lower()
            if resp == "yes":
                confirmed = True
                break
            if resp == "no":
                print("  Cancelled.")
                break
            print("  Please type 'yes' or 'no'.")

        if not confirmed:
            continue

        if action == "pool":
            print(f"\n  Restarting app pool '{target}'...", end=" ", flush=True)
            script = RESTART_APPPOOL_SCRIPT.replace("{pool_name}", target)
            stdout, status = run_ssm_command(profile, region, instance_id, script)
            if status == "Success":
                print("OK")
                for line in stdout.split("\n"):
                    if line.startswith("STATUS|"):
                        parts = line.split("|")
                        if len(parts) == 3:
                            state_color = GREEN if parts[2].strip() == "Started" else RED
                            print(f"  {parts[1]}: {state_color}{parts[2].strip()}{RESET}")
            else:
                print(f"FAILED ({status})")

        elif action == "iis":
            print(f"\n  Running iisreset on {server_name}...", end=" ", flush=True)
            stdout, status = run_ssm_command(profile, region, instance_id, RESTART_IIS_SCRIPT, timeout=120)
            if status == "Success":
                print("OK")
                section = None
                for line in stdout.split("\n"):
                    line = line.strip()
                    if line == "===APP_POOLS===":
                        print(f"\n  App Pools after restart:")
                        section = "pools"
                        continue
                    elif line == "===SITES===":
                        print(f"\n  Sites after restart:")
                        section = "sites"
                        continue
                    if not line:
                        continue
                    parts = line.split("|")
                    if section and len(parts) >= 1:
                        state = parts[1].strip() if len(parts) >= 2 and parts[1].strip() else "Started"
                        state_color = GREEN if state == "Started" else RED
                        print(f"    {parts[0]}: {state_color}{state}{RESET}")
            else:
                print(f"FAILED ({status})")

        elif action == "reboot":
            print(f"\n  Rebooting {server_name}...", end=" ", flush=True)
            stdout, status = run_ssm_command(profile, region, instance_id, REBOOT_SCRIPT, timeout=30)
            print("Reboot command sent.")
            print(f"  {YELLOW}Server will be unavailable for a few minutes.{RESET}")
            print(f"  Wait 3-5 minutes, then verify the service URL is back up.")
            return  # Exit after reboot — server is going down


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
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
    else:
        profiles = load_all_profiles()
        if not profiles:
            print("No profiles found in accounts.json")
            sys.exit(1)
        profile = pick_profile_gui(profiles)
        if not profile:
            print("No profile selected. Exiting.")
            sys.exit(0)
        sso_session = get_sso_session_for_profile(profile)

    print(f"\nSelected OU: {profile}")
    ensure_profile_session(profile, sso_session)

    # 2. Parse alert
    alert = parse_alert()

    print(f"\n{'='*60}")
    print(f"  Alert Details")
    print(f"{'='*60}")
    if alert["client_code"]:
        print(f"  Client Code:    {CYAN}{alert['client_code']}{RESET}")
    if alert["service_url"]:
        print(f"  Service URL:    {alert['service_url']}")
    if alert["service_group"]:
        print(f"  Service Group:  {alert['service_group']}")
    if alert["datacenter"]:
        print(f"  Datacenter:     {alert['datacenter']}")
    if alert["value"]:
        print(f"  Alert Value:    {RED}{alert['value']}{RESET}")
    if alert["start"]:
        print(f"  Started:        {alert['start']}")

    # 3. Confirm client code or enter manually
    search_code = alert["client_code"]
    while True:
        if search_code:
            resp = input(f"\nClient code detected: {search_code}. Type 'yes' to search with this, or enter a different client code: ").strip()
            if resp.lower() == "yes":
                break
            if resp:
                search_code = resp.upper()
                continue
            print("  Please type 'yes' or enter a client code.")
        else:
            search_code = input("\nCould not detect client code. Enter client code to search: ").strip().upper()
            if search_code:
                break
            print("  Client code is required.")

    # 4. Find instances
    print(f"\nSearching for '{search_code}'...")
    instances = find_instances(profile, search_code)

    if not instances:
        print("\nNo instances found.")
        alt = input("Enter a different search term (or 'q' to quit): ").strip()
        if alt.lower() == "q":
            sys.exit(0)
        instances = find_instances(profile, alt)
        if not instances:
            print("No instances found. Exiting.")
            sys.exit(1)

    # Display and select
    print(f"\n{'#':<4} {'Name':<35} {'Instance ID':<22} {'Private IP':<16} {'Region'}")
    print("-" * 95)
    for i, inst in enumerate(instances, 1):
        print(f"{i:<4} {inst['Name']:<35} {inst['InstanceId']:<22} {inst['PrivateIp']:<16} {inst['Region']}")

    while True:
        sel = input("\nSelect server by number: ").strip()
        if sel.isdigit() and 1 <= int(sel) <= len(instances):
            break
        print("  Invalid selection. Please enter a valid number.")

    server = instances[int(sel) - 1]
    iid = server["InstanceId"]
    region = server["Region"]
    print(f"\nSelected: {server['Name']} ({iid}) - {region}")

    # 5. Check SSM
    print("\nChecking SSM connectivity...", end=" ")
    if not check_ssm_available(profile, region, iid):
        print("OFFLINE")
        print("  SSM agent not available. Cannot proceed.")
        sys.exit(1)
    print("CONNECTED")

    # 6. Investigate
    print(f"\n{'='*80}")
    print(f"  INVESTIGATING: {server['Name']}")
    print(f"{'='*80}")

    app_pools, sites = investigate_iis(profile, region, iid)
    event_logs = investigate_events(profile, region, iid)

    # 7. Display findings with highlights
    issues, has_stopped_pools, has_stopped_sites, has_db_issues = display_findings(
        app_pools, sites, event_logs, alert["service_url"]
    )

    # 8. Offer remediation
    offer_actions(profile, region, iid, server["Name"], app_pools, has_stopped_pools, has_db_issues)

    print("\n=== Investigation complete ===")


if __name__ == "__main__":
    main()
