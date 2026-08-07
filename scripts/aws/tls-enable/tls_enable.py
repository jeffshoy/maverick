"""
TLS 1.2 Enablement Tool
Enables TLS 1.2 (SChannel server/client) and .NET strong crypto on Windows
EC2 instances via AWS SSM, then schedules a one-time reboot for 5:00 AM
server-local time so the change takes effect outside business hours.

Modes:
  --check          (default) Read-only: reports current registry state,
                   timezone, and any pending reboot task. No changes.
  --apply          Set registry values if not already correct, then
                   schedule the 5am-local reboot. Idempotent: if a target
                   is already fully compliant, no changes are made and no
                   reboot is scheduled.
  --apply --dry-run
                   Run the check payload only and report what --apply
                   would do. No changes.
  --cancel-reboot  Unregister the CloudOps-TLS12-Reboot scheduled task
                   without touching any registry values.

Targeting is always explicit — no implicit "all instances" discovery:
  --instance i-0123456789abcdef0   (repeatable)
  --name SERVERNAME                (repeatable; exact, case-insensitive
                                     match on the EC2 Name tag)

Usage:
  python tls_enable.py --account pac-stg --name PACSTG-PWEBWB001 --check
  python tls_enable.py --account pac-stg --name PACSTG-PWEBWB001 --apply --dry-run
  python tls_enable.py --account pac-stg --name PACSTG-PWEBWB001 --apply
  python tls_enable.py --account pac-prd --instance i-0123456789abcdef0 --apply --yes
  python tls_enable.py --account pac-stg --name PACSTG-PWEBWB001 --cancel-reboot

Requires: pip install boto3
"""

import argparse
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import boto3

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from aws_sso_helper import resolve_account, ensure_profile_session

REGIONS = ["us-east-1", "us-west-2", "ca-central-1"]

_HERE = Path(__file__).resolve().parent
CHECK_SCRIPT_PATH = _HERE / "Check-Tls12.ps1"
ENABLE_SCRIPT_PATH = _HERE / "Enable-Tls12.ps1"

CANCEL_SCRIPT = r"""
$task = Get-ScheduledTask -TaskName 'CloudOps-TLS12-Reboot' -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName 'CloudOps-TLS12-Reboot' -Confirm:$false
    Write-Output "RESULT|CANCELLED"
} else {
    Write-Output "RESULT|NO_TASK_FOUND"
}
"""


# =============================================================================
# AWS / SSM helpers
# =============================================================================

def get_client(profile, service, region):
    return boto3.Session(profile_name=profile, region_name=region).client(service)


def find_instance_by_name(profile, name, region_filter=None):
    """Exact, case-insensitive match on the Name tag. Returns the single match
    or raises ValueError listing candidates if zero or more than one match."""
    regions = [region_filter] if region_filter else REGIONS
    matches = []
    for region in regions:
        ec2 = get_client(profile, "ec2", region)
        paginator = ec2.get_paginator("describe_instances")
        pages = paginator.paginate(Filters=[
            {"Name": "instance-state-name", "Values": ["running", "stopped", "stopping", "pending"]},
        ])
        for page in pages:
            for res in page["Reservations"]:
                for inst in res["Instances"]:
                    tag_name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "")
                    if tag_name.lower() == name.lower():
                        matches.append({
                            "InstanceId": inst["InstanceId"],
                            "Name": tag_name,
                            "Region": region,
                        })
    if not matches:
        raise ValueError(f"No instance found with Name tag exactly matching '{name}' in {regions}.")
    if len(matches) > 1:
        listing = "; ".join(f"{m['InstanceId']} ({m['Region']})" for m in matches)
        raise ValueError(f"Multiple instances match Name '{name}': {listing}. Use --instance to disambiguate.")
    return matches[0]


def find_instance_by_id(profile, instance_id, region_filter=None):
    regions = [region_filter] if region_filter else REGIONS
    for region in regions:
        ec2 = get_client(profile, "ec2", region)
        try:
            resp = ec2.describe_instances(InstanceIds=[instance_id])
        except Exception:
            continue
        for res in resp.get("Reservations", []):
            for inst in res["Instances"]:
                tag_name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "")
                return {"InstanceId": instance_id, "Name": tag_name or "N/A", "Region": region}
    raise ValueError(f"Instance '{instance_id}' not found in {regions}.")


def get_platform_info(profile, region, instance_id):
    ssm = get_client(profile, "ssm", region)
    resp = ssm.describe_instance_information(
        Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
    )
    info = resp.get("InstanceInformationList", [])
    return info[0] if info else None


def run_ssm_command(profile, region, instance_id, script, timeout=120):
    ssm = get_client(profile, "ssm", region)
    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunPowerShellScript",
            Parameters={"commands": [script]},
            TimeoutSeconds=timeout,
        )
    except Exception as e:
        return "", str(e), "ERROR"
    cmd_id = resp["Command"]["CommandId"]
    poll_interval = 3
    max_polls = (timeout // poll_interval) + 20
    for _ in range(max_polls):
        time.sleep(poll_interval)
        try:
            inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
            if inv["Status"] in ("Success", "Failed", "TimedOut", "Cancelled"):
                return inv.get("StandardOutputContent", "").strip(), inv.get("StandardErrorContent", "").strip(), inv["Status"]
        except Exception:
            continue
    return "", "", "TimedOut"


def parse_kv(stdout: str) -> dict:
    result = {}
    for line in stdout.splitlines():
        if "|" in line:
            key, _, value = line.partition("|")
            result[key.strip()] = value.strip()
    return result


# =============================================================================
# Reporting
# =============================================================================

def print_check_result(name, instance_id, kv, status, stderr):
    print(f"\n--- {name} ({instance_id}) ---")
    if status != "Success":
        print(f"  SSM STATUS: {status}")
        if stderr:
            print(f"  STDERR: {stderr}")
        return
    print(f"  Timezone:        {kv.get('TIMEZONE', 'N/A')}")
    print(f"  Local clock:     {kv.get('CLOCK_LOCAL', 'N/A')}")
    print(f"  Server Enabled/DisabledByDefault:  {kv.get('REG_SERVER_ENABLED', 'N/A')}/{kv.get('REG_SERVER_DISABLEDBYDEFAULT', 'N/A')}")
    print(f"  Client Enabled/DisabledByDefault:  {kv.get('REG_CLIENT_ENABLED', 'N/A')}/{kv.get('REG_CLIENT_DISABLEDBYDEFAULT', 'N/A')}")
    print(f"  .NET StrongCrypto (x64/Wow64):     {kv.get('REG_NET_STRONGCRYPTO', 'N/A')}/{kv.get('REG_NET_STRONGCRYPTO_WOW64', 'N/A')}")
    print(f"  Pending reboot task: {kv.get('TASK_EXISTS', 'N/A')} (next run: {kv.get('TASK_NEXTRUN', 'N/A')})")
    print(f"  RESULT: {kv.get('RESULT', 'UNKNOWN')}")


def print_apply_result(name, instance_id, kv, status, stderr):
    print(f"\n--- {name} ({instance_id}) ---")
    if status != "Success":
        print(f"  SSM STATUS: {status}")
        if stderr:
            print(f"  STDERR: {stderr}")
        return
    result = kv.get("RESULT", "UNKNOWN")
    if result == "ALREADY_COMPLIANT":
        print("  Already compliant — no changes made, no reboot scheduled.")
        return
    print(f"  Values changed:  {kv.get('CHANGED', 'N/A')}")
    print(f"  Task:            {kv.get('TASK', 'N/A')}")
    print(f"  Reboot at:       {kv.get('REBOOT_AT', 'N/A')} ({kv.get('TIMEZONE', 'N/A')})")
    print(f"  RESULT: {result}")


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Enable TLS 1.2 + .NET strong crypto on Windows EC2 instances via SSM, "
                    "with a deferred 5am-local reboot."
    )
    parser.add_argument("--account", required=True, help="Account name or nickname (e.g. pac-stg, pac-prd)")
    parser.add_argument("--region", help="Restrict to a single region (default: search us-east-1, us-west-2, ca-central-1)")
    parser.add_argument("--instance", action="append", metavar="INSTANCE_ID", help="Target instance ID (repeatable)")
    parser.add_argument("--name", action="append", metavar="NAME", help="Target by exact EC2 Name tag (repeatable)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Read-only diagnostic (default)")
    mode.add_argument("--apply", action="store_true", help="Apply registry values and schedule 5am-local reboot")
    mode.add_argument("--cancel-reboot", action="store_true", help="Unregister the pending reboot task only")
    parser.add_argument("--dry-run", action="store_true", help="With --apply: run the check only, report intended action, make no changes")
    parser.add_argument("--yes", action="store_true", help="Skip the interactive confirmation prompt")
    args = parser.parse_args()

    if not args.instance and not args.name:
        parser.error("Provide --instance INSTANCE_ID and/or --name NAME (repeatable). No implicit fleet targeting.")
    if args.dry_run and not args.apply:
        parser.error("--dry-run is only valid together with --apply")

    try:
        acct = resolve_account(args.account)
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)
    profile = acct["profile"]
    print(f"Account: {acct['name']} ({acct['org']}, {acct['accountId']})")
    ensure_profile_session(profile, acct["ssoSession"])

    targets = []
    try:
        for iid in (args.instance or []):
            targets.append(find_instance_by_id(profile, iid, args.region))
        for name in (args.name or []):
            targets.append(find_instance_by_name(profile, name, args.region))
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)

    # Pre-flight: confirm SSM-online and Windows for every target
    verified = []
    for t in targets:
        info = get_platform_info(profile, t["Region"], t["InstanceId"])
        if not info:
            print(f"ERROR: {t['InstanceId']} ({t['Name']}) not visible via SSM in {t['Region']} — offline or agent unreachable. Refusing to target it.")
            sys.exit(1)
        if info.get("PingStatus") != "Online":
            print(f"ERROR: {t['InstanceId']} ({t['Name']}) SSM PingStatus is '{info.get('PingStatus')}', not Online. Refusing to target it.")
            sys.exit(1)
        if info.get("PlatformType") != "Windows":
            print(f"ERROR: {t['InstanceId']} ({t['Name']}) is not Windows per SSM (platform={info.get('PlatformName')} {info.get('PlatformType')}). Refusing to target it.")
            sys.exit(1)
        verified.append(t)
    targets = verified

    mode_label = "CHECK"
    if args.cancel_reboot:
        mode_label = "CANCEL-REBOOT"
    elif args.apply:
        mode_label = "DRY-RUN (apply)" if args.dry_run else "APPLY"

    print(f"\n=== {mode_label}: {len(targets)} instance(s) in {acct['name']} ===")
    for t in targets:
        print(f"  {t['InstanceId']}  {t['Name']:<30} {t['Region']}")

    if (args.apply and not args.dry_run) or args.cancel_reboot:
        if not args.yes:
            confirm = input("\nProceed? Type 'yes' to continue: ").strip().lower()
            if confirm != "yes":
                print("Aborted — no changes made.")
                sys.exit(0)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = os.path.join(os.environ.get("TEMP", r"C:\Temp"), f"tls-enable-{timestamp}.log")
    log_lines = []
    any_failed = False

    check_script = CHECK_SCRIPT_PATH.read_text(encoding="utf-8")
    enable_script = ENABLE_SCRIPT_PATH.read_text(encoding="utf-8")

    if args.cancel_reboot:
        for t in targets:
            iid = t["InstanceId"]
            stdout, stderr, status = run_ssm_command(profile, t["Region"], iid, CANCEL_SCRIPT, timeout=60)
            kv = parse_kv(stdout)
            print(f"\n--- {t['Name']} ({iid}) ---")
            if status != "Success":
                print(f"  SSM STATUS: {status}")
                if stderr:
                    print(f"  STDERR: {stderr}")
                any_failed = True
            else:
                print(f"  RESULT: {kv.get('RESULT', 'UNKNOWN')}")
            log_lines.append(f"[{iid}] cancel-reboot status={status} result={kv.get('RESULT')}")

    elif args.apply:
        for t in targets:
            iid = t["InstanceId"]
            if args.dry_run:
                stdout, stderr, status = run_ssm_command(profile, t["Region"], iid, check_script, timeout=60)
                kv = parse_kv(stdout)
                print_check_result(t["Name"], iid, kv, status, stderr)
                if status == "Success":
                    would = "no action needed (already COMPLIANT)" if kv.get("RESULT") == "COMPLIANT" else "would apply registry changes and schedule a 5am-local reboot"
                    print(f"  DRY-RUN: {would}")
                else:
                    any_failed = True
                log_lines.append(f"[{iid}] dry-run result={kv.get('RESULT')}")
            else:
                stdout, stderr, status = run_ssm_command(profile, t["Region"], iid, enable_script, timeout=120)
                kv = parse_kv(stdout)
                print_apply_result(t["Name"], iid, kv, status, stderr)
                if status != "Success":
                    any_failed = True
                log_lines.append(
                    f"[{iid}] apply status={status} result={kv.get('RESULT')} "
                    f"changed={kv.get('CHANGED')} task={kv.get('TASK')} reboot_at={kv.get('REBOOT_AT')}"
                )

    else:
        for t in targets:
            iid = t["InstanceId"]
            stdout, stderr, status = run_ssm_command(profile, t["Region"], iid, check_script, timeout=60)
            kv = parse_kv(stdout)
            print_check_result(t["Name"], iid, kv, status, stderr)
            if status != "Success":
                any_failed = True
            log_lines.append(f"[{iid}] check status={status} result={kv.get('RESULT')}")

    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "w", encoding="utf-8") as fh:
            fh.write(f"tls-enable run {timestamp} account={acct['name']} mode={mode_label}\n")
            fh.write("\n".join(log_lines))
            fh.write("\n")
        print(f"\nLog written to: {log_path}")
    except Exception as e:
        print(f"WARNING: Could not write log file: {e}")

    if any_failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
