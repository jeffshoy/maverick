"""
Foundation Site Monitor - IIS Recycle Fix Tool
Diagnoses app pool memory leaks, ping failures, WAS/W3SVC crashes,
NETLOGON/DC auth issues, and applies safe recycling fixes via SSM.

Usage:  python investigate_recycle_fix.py
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
# PowerShell diagnostic scripts
# ---------------------------------------------------------------------------
DIAG_SCRIPT = r'''
Import-Module WebAdministration -ErrorAction SilentlyContinue

Write-Output "===HOSTNAME==="
hostname

Write-Output "===APP_POOL_RECYCLING==="
Get-ChildItem IIS:\AppPools | ForEach-Object {
    $n = $_.Name
    $s = $_.State
    $identity = $_.processModel.identityType
    $user = $_.processModel.userName
    $recycleMin = $_.recycling.periodicRestart.time.TotalMinutes
    $privMem = $_.recycling.periodicRestart.privateMemory
    $idleMin = $_.processModel.idleTimeout.TotalMinutes
    $pingResp = $_.processModel.pingResponseTime.TotalSeconds
    Write-Output "$n|$s|$identity|$user|$recycleMin|$privMem|$idleMin|$pingResp"
}

Write-Output "===W3WP_PROCESSES==="
Get-Process w3wp -ErrorAction SilentlyContinue | ForEach-Object {
    $memGB = [math]::Round($_.WorkingSet64/1GB, 2)
    Write-Output "$($_.Id)|$memGB|$($_.StartTime)"
}

Write-Output "===MEMORY==="
$os = Get-CimInstance Win32_OperatingSystem
$totalGB = [math]::Round($os.TotalVisibleMemorySize/1MB, 1)
$freeGB = [math]::Round($os.FreePhysicalMemory/1MB, 1)
$usedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory)/$os.TotalVisibleMemorySize)*100, 1)
Write-Output "$totalGB|$freeGB|$usedPct"

Write-Output "===PING_FAILURES==="
Get-WinEvent -FilterHashtable @{LogName='System';Id=5010;StartTime=(Get-Date).AddDays(-7)} -MaxEvents 50 -ErrorAction SilentlyContinue | ForEach-Object {
    $time = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
    $msg = $_.Message -replace "`r`n|`n", " "
    $pool = ""
    if ($msg -match "application pool '([^']+)'") { $pool = $Matches[1] }
    Write-Output "$time|$pool"
}

Write-Output "===WAS_CRASHES==="
Get-WinEvent -FilterHashtable @{LogName='System';Id=7034,7031;StartTime=(Get-Date).AddDays(-14)} -ErrorAction SilentlyContinue | Where-Object {$_.Message -match 'Web|WAS|Process Activation|Superion'} | ForEach-Object {
    $time = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
    $msg = ($_.Message -replace "`r`n|`n", " ").Substring(0, [Math]::Min($_.Message.Length, 150))
    Write-Output "$time|$msg"
}

Write-Output "===NETLOGON_ERRORS==="
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='NETLOGON';Level=2;StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue | ForEach-Object {
    $time = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
    $msg = ($_.Message -replace "`r`n|`n", " ").Substring(0, [Math]::Min($_.Message.Length, 120))
    Write-Output "$time|$msg"
}

Write-Output "===SERVICES==="
Get-Service | Where-Object {$_.DisplayName -match 'Superion|Trakit|TRAKiT'} | ForEach-Object {
    Write-Output "$($_.Name)|$($_.DisplayName)|$($_.Status)|$($_.StartType)"
}
'''

APPLY_RECYCLE_FIX_SCRIPT = r'''
Import-Module WebAdministration -ErrorAction SilentlyContinue
$pools = @({pool_list})
foreach ($p in $pools) {{
    if (Test-Path "IIS:\AppPools\$p") {{
        $beforeRecycle = (Get-ItemProperty "IIS:\AppPools\$p" -Name recycling.periodicRestart.time).Value.TotalMinutes
        $beforeMem = (Get-ItemProperty "IIS:\AppPools\$p" -Name recycling.periodicRestart.privateMemory).Value
        Set-ItemProperty "IIS:\AppPools\$p" -Name recycling.periodicRestart.time -Value ([TimeSpan]::FromMinutes(1740))
        Set-ItemProperty "IIS:\AppPools\$p" -Name recycling.periodicRestart.privateMemory -Value 4000000
        $afterRecycle = (Get-ItemProperty "IIS:\AppPools\$p" -Name recycling.periodicRestart.time).Value.TotalMinutes
        $afterMem = (Get-ItemProperty "IIS:\AppPools\$p" -Name recycling.periodicRestart.privateMemory).Value
        Write-Output "FIXED|$p|$beforeRecycle|$beforeMem|$afterRecycle|$afterMem"
    }} else {{
        Write-Output "NOTFOUND|$p"
    }}
}}
'''

RESTART_SERVICES_SCRIPT = r'''
$services = @({service_list})
foreach ($svc in $services) {{
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) {{
        if ($s.Status -ne 'Running') {{
            Start-Service $svc -ErrorAction Stop
            Start-Sleep -Seconds 3
            $after = (Get-Service $svc).Status
            Write-Output "STARTED|$svc|$after"
        }} else {{
            Write-Output "ALREADY_RUNNING|$svc|Running"
        }}
    }} else {{
        Write-Output "NOTFOUND|$svc"
    }}
}}
'''

APPLY_PING_TIMEOUT_FIX_SCRIPT = r'''
Import-Module WebAdministration -ErrorAction SilentlyContinue
$pools = @({pool_list})
foreach ($p in $pools) {{
    if (Test-Path "IIS:\AppPools\$p") {{
        $before = (Get-ItemProperty "IIS:\AppPools\$p" -Name processModel.pingResponseTime).Value.TotalSeconds
        Set-ItemProperty "IIS:\AppPools\$p" -Name processModel.pingResponseTime -Value ([TimeSpan]::FromSeconds(120))
        $after = (Get-ItemProperty "IIS:\AppPools\$p" -Name processModel.pingResponseTime).Value.TotalSeconds
        Write-Output "FIXED|$p|$before|$after"
    }} else {{
        Write-Output "NOTFOUND|$p"
    }}
}}
'''


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
        for page in paginator.paginate(Filters=[
            {"Name": "instance-state-name", "Values": ["running"]},
            {"Name": "tag:Name", "Values": [f"*{search_code}*PTRK*"]}
        ]):
            for res in page["Reservations"]:
                for inst in res["Instances"]:
                    name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "")
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


def run_ssm_command(profile, region, instance_id, script, timeout=120):
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
    for _ in range(60):
        time.sleep(2)
        try:
            inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
            if inv["Status"] in ("Success", "Failed", "TimedOut", "Cancelled"):
                return inv.get("StandardOutputContent", "").strip(), inv["Status"]
        except Exception:
            continue
    return "", "TimedOut"


# ---------------------------------------------------------------------------
# Parsing diagnostic output
# ---------------------------------------------------------------------------
def parse_diagnostics(output):
    results = {
        "hostname": "",
        "app_pools": [],
        "w3wp": [],
        "memory": {},
        "ping_failures": [],
        "was_crashes": [],
        "netlogon_errors": [],
        "services": [],
    }
    section = None
    for line in output.split("\n"):
        line = line.strip()
        if line == "===HOSTNAME===":
            section = "hostname"; continue
        elif line == "===APP_POOL_RECYCLING===":
            section = "pools"; continue
        elif line == "===W3WP_PROCESSES===":
            section = "w3wp"; continue
        elif line == "===MEMORY===":
            section = "memory"; continue
        elif line == "===PING_FAILURES===":
            section = "ping"; continue
        elif line == "===WAS_CRASHES===":
            section = "was"; continue
        elif line == "===NETLOGON_ERRORS===":
            section = "netlogon"; continue
        elif line == "===SERVICES===":
            section = "services"; continue
        if not line:
            continue

        if section == "hostname":
            results["hostname"] = line
        elif section == "pools":
            parts = line.split("|")
            if len(parts) >= 7:
                results["app_pools"].append({
                    "Name": parts[0], "State": parts[1], "Identity": parts[2],
                    "User": parts[3], "RecycleMin": parts[4], "PrivMemKB": parts[5],
                    "IdleMin": parts[6],
                    "PingResponseSec": parts[7] if len(parts) > 7 else "90",
                })
        elif section == "w3wp":
            parts = line.split("|")
            if len(parts) == 3:
                results["w3wp"].append({"PID": parts[0], "MemGB": parts[1], "StartTime": parts[2]})
        elif section == "memory":
            parts = line.split("|")
            if len(parts) == 3:
                results["memory"] = {"TotalGB": parts[0], "FreeGB": parts[1], "UsedPct": parts[2]}
        elif section == "ping":
            parts = line.split("|", 1)
            if len(parts) == 2:
                results["ping_failures"].append({"Time": parts[0], "Pool": parts[1]})
        elif section == "was":
            parts = line.split("|", 1)
            if len(parts) == 2:
                results["was_crashes"].append({"Time": parts[0], "Message": parts[1]})
        elif section == "netlogon":
            parts = line.split("|", 1)
            if len(parts) == 2:
                results["netlogon_errors"].append({"Time": parts[0], "Message": parts[1]})
        elif section == "services":
            parts = line.split("|")
            if len(parts) == 4:
                results["services"].append({
                    "Name": parts[0], "DisplayName": parts[1],
                    "Status": parts[2], "StartType": parts[3],
                })
    return results


# ---------------------------------------------------------------------------
# Display findings
# ---------------------------------------------------------------------------
def display_findings(results):
    hostname = results["hostname"]
    issues = []

    print(f"\n{'='*80}")
    print(f"  SERVER: {CYAN}{hostname}{RESET}")
    print(f"{'='*80}")

    # Memory
    mem = results["memory"]
    if mem:
        used_pct = float(mem["UsedPct"])
        color = RED if used_pct > 80 else YELLOW if used_pct > 60 else GREEN
        print(f"\n  Memory: Total {mem['TotalGB']} GB | Free {mem['FreeGB']} GB | {color}Used {mem['UsedPct']}%{RESET}")

    # App Pool Recycling Config
    print(f"\n  {'Pool Name':<25} {'State':<10} {'Recycle(min)':<14} {'PrivMem(KB)':<13} {'PingResp(s)':<13} {'User'}")
    print(f"  {'-'*110}")
    pools_needing_fix = []
    pools_needing_ping_fix = []
    for pool in results["app_pools"]:
        recycle = pool["RecycleMin"]
        privmem = pool["PrivMemKB"]
        ping_resp = pool.get("PingResponseSec", "90")
        name_lower = pool["Name"].lower()
        is_trakit = any(k in name_lower for k in ["trakit", "etrakit", "itrakit"])
        needs_fix = is_trakit and (recycle == "0" or privmem == "0")

        if needs_fix:
            prefix = f"  {HIGHLIGHT}"
            suffix = RESET
            pools_needing_fix.append(pool["Name"])
            issues.append(f"Pool '{pool['Name']}' has NO recycling (Recycle={recycle}min, PrivMem={privmem}KB)")
        elif pool["State"] != "Started":
            prefix = f"  {RED}"
            suffix = RESET
            issues.append(f"Pool '{pool['Name']}' is {pool['State']}")
        else:
            prefix = "  "
            suffix = ""
        print(f"{prefix}{pool['Name']:<25} {pool['State']:<10} {recycle:<14} {privmem:<13} {ping_resp:<13} {pool.get('User','')}{suffix}")

    # W3WP Processes
    print(f"\n  W3WP Processes:")
    print(f"  {'PID':<10} {'Memory (GB)':<14} {'Start Time'}")
    print(f"  {'-'*50}")
    for proc in results["w3wp"]:
        mem_gb = float(proc["MemGB"])
        color = RED if mem_gb > 3 else YELLOW if mem_gb > 1.5 else ""
        reset_c = RESET if color else ""
        print(f"  {color}{proc['PID']:<10} {proc['MemGB']:<14} {proc['StartTime']}{reset_c}")
        if mem_gb > 3:
            issues.append(f"w3wp PID {proc['PID']} using {proc['MemGB']} GB (memory leak)")

    # Ping Failures
    if results["ping_failures"]:
        print(f"\n  {HIGHLIGHT} App Pool Ping Failures (last 7 days): {len(results['ping_failures'])} events {RESET}")
        # Group by pool
        pool_counts = {}
        for pf in results["ping_failures"]:
            pool_counts[pf["Pool"]] = pool_counts.get(pf["Pool"], 0) + 1
        for pool, count in sorted(pool_counts.items(), key=lambda x: -x[1]):
            print(f"    {RED}{pool}: {count} failures{RESET}")
            issues.append(f"Pool '{pool}' had {count} ping failures in 7 days")
            # Check if this pool needs ping timeout increase
            pool_info = next((p for p in results["app_pools"] if p["Name"].lower() == pool.lower()), None)
            if pool_info and float(pool_info.get("PingResponseSec", "90")) < 120 and count >= 5:
                pools_needing_ping_fix.append(pool_info["Name"])
        # Show last 5
        print(f"\n  Last 5 ping failures:")
        for pf in results["ping_failures"][:5]:
            print(f"    {pf['Time']} - {pf['Pool']}")
        if pools_needing_ping_fix:
            print(f"\n  {YELLOW}Pools with frequent ping failures and low timeout (<120s): {', '.join(pools_needing_ping_fix)}{RESET}")
            issues.append(f"Ping response timeout too low on: {', '.join(pools_needing_ping_fix)} (needs 120s)")

    # WAS Crashes
    if results["was_crashes"]:
        print(f"\n  {HIGHLIGHT} WAS/W3SVC Crashes (last 14 days): {len(results['was_crashes'])} events {RESET}")
        for crash in results["was_crashes"][:5]:
            print(f"    {RED}{crash['Time']} - {crash['Message'][:80]}{RESET}")
            issues.append(f"WAS crash: {crash['Time']} - {crash['Message'][:60]}")

    # NETLOGON Errors
    if results["netlogon_errors"]:
        print(f"\n  {YELLOW}NETLOGON Errors (last 7 days): {len(results['netlogon_errors'])} events{RESET}")
        for err in results["netlogon_errors"][:3]:
            print(f"    {YELLOW}{err['Time']} - {err['Message'][:80]}{RESET}")
        if len(results["netlogon_errors"]) > 3:
            print(f"    ... and {len(results['netlogon_errors']) - 3} more")
        issues.append(f"{len(results['netlogon_errors'])} NETLOGON/DC auth errors in 7 days")

    # Services
    stopped_services = [s for s in results["services"] if s["Status"] != "Running"]
    if stopped_services:
        print(f"\n  {HIGHLIGHT} Stopped Services: {RESET}")
        for svc in stopped_services:
            print(f"    {RED}{svc['Name']} ({svc['DisplayName']}) - {svc['Status']}{RESET}")
            issues.append(f"Service '{svc['Name']}' is {svc['Status']}")

    # Summary
    print(f"\n{'='*80}")
    print(f"  DIAGNOSIS SUMMARY")
    print(f"{'='*80}")
    if not issues:
        print(f"\n  {GREEN}No issues found. Recycling is configured and services are healthy.{RESET}")
    else:
        print(f"\n  {RED}{len(issues)} issue(s) detected:{RESET}\n")
        for i, issue in enumerate(issues, 1):
            print(f"  {i}. {issue}")

    return issues, pools_needing_fix, pools_needing_ping_fix, stopped_services


# ---------------------------------------------------------------------------
# Apply fixes
# ---------------------------------------------------------------------------
def apply_recycle_fix(profile, region, instance_id, pools):
    pool_list_str = ",".join(f"'{p}'" for p in pools)
    script = APPLY_RECYCLE_FIX_SCRIPT.replace("{pool_list}", pool_list_str)
    print(f"\n  Applying recycling fix (1740 min + 4GB memory limit)...", end=" ", flush=True)
    stdout, status = run_ssm_command(profile, region, instance_id, script)
    if status != "Success":
        print(f"{RED}FAILED ({status}){RESET}")
        return False
    print(f"{GREEN}OK{RESET}")
    print(f"\n  {'Pool':<25} {'Before Recycle':<16} {'Before Mem':<14} {'After Recycle':<16} {'After Mem'}")
    print(f"  {'-'*85}")
    for line in stdout.split("\n"):
        line = line.strip()
        if line.startswith("FIXED|"):
            parts = line.split("|")
            if len(parts) == 6:
                print(f"  {GREEN}{parts[1]:<25} {parts[2]+'min':<16} {parts[3]+'KB':<14} {parts[4]+'min':<16} {parts[5]}KB{RESET}")
        elif line.startswith("NOTFOUND|"):
            pool = line.split("|")[1]
            print(f"  {YELLOW}{pool:<25} NOT FOUND{RESET}")
    return True


def apply_ping_timeout_fix(profile, region, instance_id, pools):
    pool_list_str = ",".join(f"'{p}'" for p in pools)
    script = APPLY_PING_TIMEOUT_FIX_SCRIPT.replace("{pool_list}", pool_list_str)
    print(f"\n  Increasing ping response timeout to 120 sec...", end=" ", flush=True)
    stdout, status = run_ssm_command(profile, region, instance_id, script)
    if status != "Success":
        print(f"{RED}FAILED ({status}){RESET}")
        return False
    print(f"{GREEN}OK{RESET}")
    print(f"\n  {'Pool':<25} {'Before (sec)':<16} {'After (sec)'}")
    print(f"  {'-'*55}")
    for line in stdout.split("\n"):
        line = line.strip()
        if line.startswith("FIXED|"):
            parts = line.split("|")
            if len(parts) == 4:
                print(f"  {GREEN}{parts[1]:<25} {parts[2]:<16} {parts[3]}{RESET}")
        elif line.startswith("NOTFOUND|"):
            pool = line.split("|")[1]
            print(f"  {YELLOW}{pool:<25} NOT FOUND{RESET}")
    return True


def restart_stopped_services(profile, region, instance_id, services):
    svc_list_str = ",".join(f"'{s['Name']}'" for s in services)
    script = RESTART_SERVICES_SCRIPT.replace("{service_list}", svc_list_str)
    print(f"\n  Restarting stopped services...", end=" ", flush=True)
    stdout, status = run_ssm_command(profile, region, instance_id, script)
    if status != "Success":
        print(f"{RED}FAILED ({status}){RESET}")
        return False
    print(f"{GREEN}OK{RESET}")
    for line in stdout.split("\n"):
        line = line.strip()
        if line.startswith("STARTED|"):
            parts = line.split("|")
            print(f"  {GREEN}Started: {parts[1]} -> {parts[2]}{RESET}")
        elif line.startswith("ALREADY_RUNNING|"):
            parts = line.split("|")
            print(f"  {parts[1]} already running")
        elif line.startswith("NOTFOUND|"):
            parts = line.split("|")
            print(f"  {YELLOW}{parts[1]} not found{RESET}")
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    print(f"\n{'='*80}")
    print(f"  IIS RECYCLE FIX & DIAGNOSTICS TOOL")
    print(f"{'='*80}")

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
        print("\nOpening AWS OU selector...")
        profile = pick_profile_gui(profiles)
        if not profile:
            sys.exit(0)
        sso_session = get_sso_session_for_profile(profile)

    print(f"\nSelected OU: {profile}")
    ensure_profile_session(profile, sso_session)

    # 2. Get client codes
    client_input = input("\nEnter client code(s) separated by commas (e.g. AURO,DNTN,PIED,REDB): ").strip()
    if not client_input:
        print("No client codes entered. Exiting.")
        sys.exit(0)
    client_codes = [c.strip().upper() for c in client_input.split(",") if c.strip()]

    # 3. Find and diagnose each client
    all_results = []
    for code in client_codes:
        print(f"\n{'#'*80}")
        print(f"  SEARCHING: {code}")
        print(f"{'#'*80}")
        instances = find_instances(profile, code)
        if not instances:
            print(f"  {YELLOW}No PTRK instances found for {code}{RESET}")
            continue

        print(f"\n  {'#':<4} {'Name':<35} {'Instance ID':<22} {'Private IP':<16} {'Region'}")
        print(f"  {'-'*95}")
        for i, inst in enumerate(instances, 1):
            print(f"  {i:<4} {inst['Name']:<35} {inst['InstanceId']:<22} {inst['PrivateIp']:<16} {inst['Region']}")

        # Diagnose each instance
        for inst in instances:
            iid = inst["InstanceId"]
            region = inst["Region"]
            print(f"\n  Checking SSM on {inst['Name']}...", end=" ")
            if not check_ssm_available(profile, region, iid):
                print(f"{RED}OFFLINE{RESET}")
                continue
            print(f"{GREEN}ONLINE{RESET}")

            print(f"  Running diagnostics on {inst['Name']}...", end=" ", flush=True)
            stdout, status = run_ssm_command(profile, region, iid, DIAG_SCRIPT)
            if status != "Success":
                print(f"{RED}FAILED ({status}){RESET}")
                continue
            print(f"{GREEN}OK{RESET}")

            results = parse_diagnostics(stdout)
            issues, pools_needing_fix, pools_needing_ping_fix, stopped_services = display_findings(results)
            all_results.append({
                "code": code,
                "instance": inst,
                "results": results,
                "issues": issues,
                "pools_needing_fix": pools_needing_fix,
                "pools_needing_ping_fix": pools_needing_ping_fix,
                "stopped_services": stopped_services,
            })

    # 4. Summary and offer fixes
    if not all_results:
        print("\nNo servers diagnosed. Exiting.")
        sys.exit(0)

    # Collect all fixable items
    fixable_pools = [(r["instance"], r["pools_needing_fix"]) for r in all_results if r["pools_needing_fix"]]
    fixable_ping = [(r["instance"], r["pools_needing_ping_fix"]) for r in all_results if r["pools_needing_ping_fix"]]
    fixable_services = [(r["instance"], r["stopped_services"]) for r in all_results if r["stopped_services"]]

    if not fixable_pools and not fixable_services and not fixable_ping:
        print(f"\n  {GREEN}No fixes needed. All app pools have recycling configured and services are running.{RESET}")
        sys.exit(0)

    print(f"\n{'='*80}")
    print(f"  RECOMMENDED FIXES")
    print(f"{'='*80}")

    if fixable_pools:
        print(f"\n  {CYAN}Recycling Fix (1740 min + 4GB private memory limit):{RESET}")
        for inst, pools in fixable_pools:
            print(f"    {inst['Name']}: {', '.join(pools)}")

    if fixable_ping:
        print(f"\n  {CYAN}Ping Response Timeout Fix (increase to 120 sec):{RESET}")
        for inst, pools in fixable_ping:
            print(f"    {inst['Name']}: {', '.join(pools)}")

    if fixable_services:
        print(f"\n  {CYAN}Service Restart:{RESET}")
        for inst, services in fixable_services:
            svc_names = [s['Name'] for s in services]
            print(f"    {inst['Name']}: {', '.join(svc_names)}")

    print(f"\n  Options:")
    print(f"  [1] Apply ALL fixes (recycling + ping timeout + service restarts)")
    print(f"  [2] Apply recycling fix only")
    print(f"  [3] Apply ping timeout fix only")
    print(f"  [4] Restart stopped services only")
    print(f"  [5] Exit without changes")

    while True:
        choice = input("\n  Select option: ").strip()
        if choice in ("1", "2", "3", "4", "5"):
            break
        print("  Please enter 1, 2, 3, 4, or 5.")

    if choice == "5":
        print("\n  No changes made. Exiting.")
        sys.exit(0)

    # Confirm
    resp = input(f"\n  Type 'yes' to confirm applying fixes: ").strip().lower()
    if resp != "yes":
        print("  Cancelled.")
        sys.exit(0)

    # Apply recycling fix
    if choice in ("1", "2") and fixable_pools:
        print(f"\n{'='*80}")
        print(f"  APPLYING RECYCLING FIX")
        print(f"{'='*80}")
        for inst, pools in fixable_pools:
            print(f"\n  Server: {inst['Name']} ({inst['Region']})")
            apply_recycle_fix(profile, inst["Region"], inst["InstanceId"], pools)

    # Apply ping timeout fix
    if choice in ("1", "3") and fixable_ping:
        print(f"\n{'='*80}")
        print(f"  APPLYING PING RESPONSE TIMEOUT FIX")
        print(f"{'='*80}")
        for inst, pools in fixable_ping:
            print(f"\n  Server: {inst['Name']} ({inst['Region']})")
            apply_ping_timeout_fix(profile, inst["Region"], inst["InstanceId"], pools)

    # Restart services
    if choice in ("1", "4") and fixable_services:
        print(f"\n{'='*80}")
        print(f"  RESTARTING STOPPED SERVICES")
        print(f"{'='*80}")
        for inst, services in fixable_services:
            print(f"\n  Server: {inst['Name']} ({inst['Region']})")
            restart_stopped_services(profile, inst["Region"], inst["InstanceId"], services)

    # Done
    print(f"\n{'='*80}")
    print(f"  {GREEN}ALL FIXES APPLIED SUCCESSFULLY{RESET}")
    print(f"{'='*80}")
    print(f"\n  Monitor LogicMonitor alerts over the next few hours to confirm resolution.")
    print(f"  The recycling will take effect on the next cycle (within 29 hours).")
    print(f"  Memory-limited pools will recycle immediately if they exceed 4 GB.\n")


if __name__ == "__main__":
    main()
