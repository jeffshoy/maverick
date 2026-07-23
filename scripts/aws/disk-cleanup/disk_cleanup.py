"""
Disk Cleanup + EBS Expansion Tool
Runs Windows disk cleanup on a fleet of servers via SSM, then auto-expands any
that still cannot reach 10% free space, targeting 30% free space post-expansion.

Usage:
    # One or more servers via CLI:
    python disk_cleanup.py --server IMP-PONSRP101 PALegacyFinEntIMP --server DALY-PXSF001 PALegacyFinEntDALY

    # Dry-run first:
    python disk_cleanup.py --dry-run --server IMP-PONSRP101 PALegacyFinEntIMP

    # From a CSV file (columns: name,account -- no header required):
    python disk_cleanup.py --file servers.csv

Requires: pip install boto3
"""

import math
import os
import re
import sys
import time
import concurrent.futures
import argparse
from datetime import datetime

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from aws_sso_helper import resolve_account, ensure_profile_session

REGIONS = ["us-east-1", "us-west-2", "ca-central-1"]

FREE_SPACE_TARGET_PCT = 10.0   # minimum % free after cleanup before triggering expand
EXPAND_TARGET_PCT = 30.0       # % free to achieve when expanding


# ---------------------------------------------------------------------------
# PowerShell scripts sent via SSM
# ---------------------------------------------------------------------------

GET_DISK_USAGE_SCRIPT = r"""
$drv = Get-PSDrive -Name C -ErrorAction Stop
$used = [Math]::Round($drv.Used / 1GB, 2)
$free = [Math]::Round($drv.Free / 1GB, 2)
$total = [Math]::Round(($drv.Used + $drv.Free) / 1GB, 2)
Write-Output "USAGE|C|$used|$free|$total"
"""

CLEANUP_SCRIPT = r"""
$ErrorActionPreference = 'SilentlyContinue'
$log = @()

function Remove-Safely {
    param([string]$Path, [string]$Label, [int]$AgeDays = 0)
    if (-not (Test-Path $Path)) { return }
    $threshold = (Get-Date).AddDays(-$AgeDays)
    $files = if ($AgeDays -gt 0) {
        Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $threshold }
    } else {
        Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue
    }
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    $files | Remove-Item -Force -ErrorAction SilentlyContinue
    $script:log += "CLEANED|$Label|$([Math]::Round($bytes / 1MB, 2)) MB"
}

# Windows Temp
Remove-Safely "$env:SystemRoot\Temp" "WindowsTemp"

# All user Temp folders
Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Safely "$($_.FullName)\AppData\Local\Temp" "UserTemp:$($_.Name)"
}

# Windows Update download cache
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Remove-Safely "C:\Windows\SoftwareDistribution\Download" "WUDownloadCache"
Start-Service wuauserv -ErrorAction SilentlyContinue

# CBS logs
Remove-Safely "C:\Windows\Logs\CBS" "CBSLogs"

# WER crash dumps
Remove-Safely "C:\ProgramData\Microsoft\Windows\WER\ReportArchive" "WERReportArchive"
Remove-Safely "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"   "WERReportQueue"

# IIS logs older than 30 days
Remove-Safely "C:\inetpub\logs\LogFiles" "IISLogs" -AgeDays 30

# Recycle Bin
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
$log += "CLEANED|RecycleBin|N/A"

# Output log lines
$log | ForEach-Object { Write-Output $_ }
Write-Output "CLEANUP_DONE"
"""

# DISM runs separately -- it has a much longer timeout and its own status line
DISM_SCRIPT = r"""
$ErrorActionPreference = 'SilentlyContinue'
Write-Output "DISM_START"
$result = dism /online /Cleanup-Image /StartComponentCleanup 2>&1
$exitCode = $LASTEXITCODE
if ($exitCode -eq 0) {
    Write-Output "DISM_OK"
} else {
    Write-Output "DISM_FAILED|exit=$exitCode"
}
"""

GET_DRIVES_SCRIPT = r"""
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
"""

EXPAND_PARTITION_SCRIPT = r"""
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
"""

# ---------------------------------------------------------------------------
# AWS helpers
# ---------------------------------------------------------------------------

def find_instance(profile, name):
    """Search all regions for a running instance matching name (case-insensitive)."""
    name_lower = name.lower()
    for region in REGIONS:
        import boto3
        session = boto3.Session(profile_name=profile, region_name=region)
        ec2 = session.client("ec2")
        paginator = ec2.get_paginator("describe_instances")
        for page in paginator.paginate(Filters=[{"Name": "instance-state-name", "Values": ["running"]}]):
            for res in page["Reservations"]:
                for inst in res["Instances"]:
                    tag_name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "")
                    if name_lower in tag_name.lower():
                        return inst["InstanceId"], region, tag_name
    return None, None, None


def check_ssm_available(profile, region, instance_id):
    import boto3
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


def run_ssm_command(profile, region, instance_id, script, timeout=300):
    import boto3
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
    poll_interval = 10 if timeout > 300 else 2
    max_polls = (timeout // poll_interval) + 30
    for _ in range(max_polls):
        time.sleep(poll_interval)
        try:
            inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
            if inv["Status"] in ("Success", "Failed", "TimedOut", "Cancelled"):
                return inv.get("StandardOutputContent", "").strip(), inv["Status"]
        except Exception:
            continue
    return "", "TimedOut"


def get_disk_usage(profile, region, instance_id):
    """Returns (used_gb, free_gb, total_gb) for C:\\ or None on failure."""
    stdout, status = run_ssm_command(profile, region, instance_id, GET_DISK_USAGE_SCRIPT, timeout=60)
    if status != "Success":
        return None
    for line in stdout.splitlines():
        if line.startswith("USAGE|"):
            parts = line.split("|")
            if len(parts) == 5:
                return float(parts[2]), float(parts[3]), float(parts[4])
    return None


def get_os_drives(profile, region, instance_id):
    stdout, status = run_ssm_command(profile, region, instance_id, GET_DRIVES_SCRIPT, timeout=60)
    if status != "Success":
        return []
    drives = []
    for line in stdout.strip().splitlines():
        parts = line.strip().split("|")
        if len(parts) == 4:
            drives.append({"DriveLetter": parts[0], "DiskNumber": parts[1], "SizeGB": parts[2], "VolumeId": parts[3]})
    return drives


def get_ebs_volumes(profile, region, instance_id):
    import boto3
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
                        volumes.append({
                            "VolumeId": vol_id,
                            "Device": bdm["DeviceName"],
                            "SizeGB": v["Size"],
                        })
    return volumes


def find_ebs_for_drive(drive_letter, os_drives, ebs_volumes):
    for d in os_drives:
        if d["DriveLetter"] == drive_letter and d["VolumeId"]:
            clean_id = re.sub(r'[._].*$', '', d["VolumeId"]).strip()
            for v in ebs_volumes:
                if v["VolumeId"] == clean_id:
                    return v
    return None


def expand_ebs_volume(profile, region, volume_id, new_size_gb):
    import boto3
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")
    ec2.modify_volume(VolumeId=volume_id, Size=new_size_gb)
    for _ in range(60):
        time.sleep(5)
        resp = ec2.describe_volumes_modifications(VolumeIds=[volume_id])
        mods = resp.get("VolumesModifications", [])
        if mods and mods[0].get("ModificationState") in ("completed", "optimizing"):
            return True
        print(".", end="", flush=True)
    print()
    return False


# ---------------------------------------------------------------------------
# Per-server logic
# ---------------------------------------------------------------------------

def process_server(server_def, dry_run, log_lines):
    name = server_def["name"]
    account_name = server_def["account"]
    prefix = f"[{name}]"

    def log(msg):
        line = f"{prefix} {msg}"
        print(line)
        log_lines.append(line)

    result = {
        "name": name,
        "account": account_name,
        "status": "unknown",
        "before_free_pct": None,
        "after_cleanup_free_pct": None,
        "after_expand_free_pct": None,
        "freed_gb": None,
        "expanded": False,
        "new_size_gb": None,
        "error": None,
    }

    # Resolve account
    try:
        acct = resolve_account(account_name)
    except ValueError as e:
        result["status"] = "error"
        result["error"] = f"Account resolve failed: {e}"
        log(f"ERROR: {e}")
        return result

    profile = acct["profile"]
    sso_session = acct["ssoSession"]

    # Ensure SSO session active (auto-refreshes if expired)
    try:
        ensure_profile_session(profile, sso_session)
    except SystemExit:
        result["status"] = "error"
        result["error"] = "SSO login failed"
        log("ERROR: SSO login failed")
        return result

    # Find instance
    log("Searching for instance...")
    instance_id, region, tag_name = find_instance(profile, name)
    if not instance_id:
        result["status"] = "error"
        result["error"] = "Instance not found in any region"
        log("ERROR: Instance not found")
        return result
    log(f"Found: {tag_name} ({instance_id}) in {region}")

    # Check SSM
    log("Checking SSM connectivity...")
    if not check_ssm_available(profile, region, instance_id):
        result["status"] = "error"
        result["error"] = "SSM agent offline"
        log("ERROR: SSM agent offline")
        return result
    log("SSM: CONNECTED")

    # Baseline disk usage
    usage = get_disk_usage(profile, region, instance_id)
    if not usage:
        result["status"] = "error"
        result["error"] = "Failed to get disk usage"
        log("ERROR: Could not fetch disk usage")
        return result
    used_before, free_before, total = usage
    free_pct_before = round(free_before / total * 100, 1) if total else 0
    result["before_free_pct"] = free_pct_before
    log(f"C:\\ BEFORE: {free_before} GB free / {total} GB total ({free_pct_before}% free)")

    if dry_run:
        log(f"DRY-RUN: Would run cleanup (Windows Temp, user Temp, WU cache, CBS logs, WER dumps, IIS logs >30d, DISM)")
        if free_pct_before < FREE_SPACE_TARGET_PCT:
            new_size = math.ceil(used_before / (1 - EXPAND_TARGET_PCT / 100))
            log(f"DRY-RUN: After cleanup, if still <{FREE_SPACE_TARGET_PCT}% free, would expand EBS to ~{new_size} GB to reach {EXPAND_TARGET_PCT}% free")
        result["status"] = "dry-run"
        return result

    # Phase 1: Cleanup
    log("Running cleanup (Temp, WU cache, CBS, WER, IIS logs)...")
    stdout, status = run_ssm_command(profile, region, instance_id, CLEANUP_SCRIPT, timeout=300)
    if status != "Success":
        log(f"WARNING: Cleanup command ended with status {status}")
    else:
        for line in stdout.splitlines():
            if line.startswith("CLEANED|"):
                parts = line.split("|")
                if len(parts) == 3:
                    log(f"  Cleaned {parts[1]}: {parts[2]}")

    # DISM (longer timeout -- up to 30 min)
    log("Running DISM component store cleanup (may take 10-20 min)...")
    stdout_dism, status_dism = run_ssm_command(profile, region, instance_id, DISM_SCRIPT, timeout=1800)
    if "DISM_OK" in stdout_dism:
        log("  DISM: completed OK")
    elif "DISM_FAILED" in stdout_dism:
        log(f"  DISM: failed -- {stdout_dism.strip()}")
    else:
        log(f"  DISM: status={status_dism} (may have timed out or partially ran)")

    # Post-cleanup usage
    usage_after = get_disk_usage(profile, region, instance_id)
    if not usage_after:
        log("WARNING: Could not fetch post-cleanup disk usage -- assuming unchanged")
        usage_after = usage
    used_after, free_after, total_after = usage_after
    free_pct_after = round(free_after / total_after * 100, 1) if total_after else 0
    freed_gb = round(free_after - free_before, 2)
    result["after_cleanup_free_pct"] = free_pct_after
    result["freed_gb"] = freed_gb
    log(f"C:\\ AFTER CLEANUP: {free_after} GB free / {total_after} GB total ({free_pct_after}% free) -- freed {freed_gb} GB")

    # Phase 2: Expand if still below threshold
    if free_pct_after >= FREE_SPACE_TARGET_PCT:
        log(f"C:\\ is now at {free_pct_after}% free -- no expansion needed.")
        result["status"] = "ok"
        return result

    log(f"Still below {FREE_SPACE_TARGET_PCT}% free -- proceeding with EBS expansion to reach {EXPAND_TARGET_PCT}% free")

    # Calculate new size: used / (1 - target%) rounded up to nearest 10 GB
    new_size_raw = used_after / (1 - EXPAND_TARGET_PCT / 100)
    new_size_gb = int(math.ceil(new_size_raw / 10)) * 10  # round up to nearest 10 GB

    # Identify EBS volume for C:\
    os_drives = get_os_drives(profile, region, instance_id)
    ebs_volumes = get_ebs_volumes(profile, region, instance_id)
    ebs_vol = find_ebs_for_drive("C", os_drives, ebs_volumes)

    if not ebs_vol:
        result["status"] = "error"
        result["error"] = "Could not map C:\\ to an EBS volume"
        log("ERROR: Could not find EBS volume ID for C:\\ drive")
        return result

    current_ebs_gb = ebs_vol["SizeGB"]
    if new_size_gb <= current_ebs_gb:
        # This can happen if DISM freed enough that the calc rounds back below current
        log(f"Calculated new size {new_size_gb} GB is not larger than current EBS size {current_ebs_gb} GB -- skipping expand")
        result["status"] = "ok"
        return result

    log(f"EBS volume {ebs_vol['VolumeId']}: {current_ebs_gb} GB -> {new_size_gb} GB")
    log("Modifying EBS volume...", )
    ok = expand_ebs_volume(profile, region, ebs_vol["VolumeId"], new_size_gb)
    if not ok:
        result["status"] = "error"
        result["error"] = "EBS modification timed out"
        log("ERROR: EBS modification did not complete in time")
        return result
    log("EBS modification complete")

    # Expand OS partition
    log("Expanding OS partition to fill new EBS space...")
    script = EXPAND_PARTITION_SCRIPT.format(drive_letter="C")
    stdout_exp, status_exp = run_ssm_command(profile, region, instance_id, script, timeout=120)
    if status_exp != "Success":
        result["status"] = "error"
        result["error"] = f"Partition resize failed: {status_exp}"
        log(f"ERROR: Partition resize returned {status_exp}")
        return result

    final_free_pct = None
    for line in stdout_exp.splitlines():
        if line.startswith("RESULT|"):
            parts = line.split("|")
            if len(parts) == 5:
                f_used, f_free, f_total = float(parts[2]), float(parts[3]), float(parts[4])
                final_free_pct = round(f_free / f_total * 100, 1)
                log(f"C:\\ AFTER EXPAND: {f_free} GB free / {f_total} GB total ({final_free_pct}% free)")

    result["expanded"] = True
    result["new_size_gb"] = new_size_gb
    result["after_expand_free_pct"] = final_free_pct
    result["status"] = "ok"
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Disk cleanup + EBS expansion for a server fleet")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be done without making any changes")
    parser.add_argument("--server", nargs=2, metavar=("NAME", "ACCOUNT"), action="append",
                        help="Server name and account (repeatable). E.g. --server IMP-PONSRP101 PALegacyFinEntIMP")
    parser.add_argument("--file", metavar="CSV",
                        help="CSV file with columns name,account (one server per line, no header)")
    args = parser.parse_args()

    servers = []
    if args.server:
        for name, account in args.server:
            servers.append({"name": name, "account": account})
    if args.file:
        import csv
        with open(args.file, newline="", encoding="utf-8") as fh:
            for row in csv.reader(fh):
                if len(row) >= 2 and row[0].strip():
                    servers.append({"name": row[0].strip(), "account": row[1].strip()})
    if not servers:
        parser.error("Provide at least one server via --server NAME ACCOUNT or --file servers.csv")

    dry_run = args.dry_run
    mode_label = "DRY-RUN" if dry_run else "LIVE"
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = os.path.join(os.environ.get("TEMP", r"C:\Temp"), f"disk-cleanup-{timestamp}.log")

    print(f"=== Disk Cleanup + EBS Expansion [{mode_label}] ===")
    print(f"Log file: {log_path}")
    print(f"Servers: {len(servers)}")
    print(f"Targets: >={FREE_SPACE_TARGET_PCT}% free after cleanup; expand to {EXPAND_TARGET_PCT}% free if needed")
    print()

    if not dry_run:
        print()


    log_lines = []

    # Resolve all unique account sessions up front (one SSO prompt per account, sequentially)
    seen_accounts = {}
    for s in servers:
        acct_name = s["account"]
        if acct_name in seen_accounts:
            continue
        try:
            acct = resolve_account(acct_name)
            ensure_profile_session(acct["profile"], acct["ssoSession"])
            seen_accounts[acct_name] = acct
        except Exception as e:
            print(f"[PREFLIGHT] WARNING: Could not authenticate {acct_name}: {e}")

    print()
    print("=== Starting cleanup pass (servers run in parallel) ===")
    print()

    results = [None] * len(servers)
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(len(servers), 5)) as pool:
        futures = {
            pool.submit(process_server, s, dry_run, log_lines): i
            for i, s in enumerate(servers)
        }
        for future in concurrent.futures.as_completed(futures):
            idx = futures[future]
            try:
                results[idx] = future.result()
            except Exception as e:
                results[idx] = {
                    "name": servers[idx]["name"],
                    "account": servers[idx]["account"],
                    "status": "error",
                    "before_free_pct": None,
                    "after_cleanup_free_pct": None,
                    "after_expand_free_pct": None,
                    "freed_gb": None,
                    "expanded": False,
                    "new_size_gb": None,
                    "error": str(e),
                }

    # Summary
    print()
    print("=" * 80)
    print("SUMMARY")
    print("=" * 80)
    hdr = f"{'Server':<22} {'Account':<24} {'Before':>8} {'After':>8} {'Freed':>8} {'Expanded':>10} {'Status'}"
    print(hdr)
    print("-" * 100)
    for r in results:
        if r is None:
            continue
        before = f"{r['before_free_pct']}%" if r['before_free_pct'] is not None else "N/A"
        after_pct = r['after_expand_free_pct'] or r['after_cleanup_free_pct']
        after = f"{after_pct}%" if after_pct is not None else "N/A"
        freed = f"{r['freed_gb']} GB" if r['freed_gb'] is not None else "N/A"
        expanded = f"+{r['new_size_gb']}GB" if r['expanded'] else "-"
        status = r['status'].upper()
        if r.get('error'):
            status = f"ERROR: {r['error']}"
        print(f"{r['name']:<22} {r['account']:<24} {before:>8} {after:>8} {freed:>8} {expanded:>10}  {status}")
    print()

    # Write log file
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "w", encoding="utf-8") as fh:
            fh.write(f"disk-cleanup run [{mode_label}] {timestamp}\n")
            fh.write("\n".join(log_lines))
            fh.write("\n")
        print(f"Log written to: {log_path}")
    except Exception as e:
        print(f"WARNING: Could not write log file: {e}")

    errors = [r for r in results if r and r["status"] == "error"]
    if errors:
        print(f"\n{len(errors)} server(s) had errors -- review log above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
