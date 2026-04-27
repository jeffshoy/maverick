"""
RDS License Reset CLI
Resets Terminal Server grace period to 120 days via AWS SSM, then force-reboots and verifies.

Usage:  python rds_license_reset.py
Requires: pip install boto3
"""

import boto3
import json
import subprocess
import sys
import time

REGIONS = {"e": "us-east-1", "w": "us-west-2"}
AWS_PROFILE = "PALegacySharedServices"
SSO_SESSION = "foundation"
DOC_NAME = "Reset-RDSGracePeriod"

SCRIPT_CONTENT = r'''
$ErrorActionPreference = "Stop"
try {
    $tsSetting = Get-WmiObject -Namespace root\cimv2\terminalservices -Class Win32_TerminalServiceSetting
    $grace = (Invoke-WmiMethod -Path $tsSetting.__PATH -Name GetGracePeriodDays).DaysLeft
    Write-Output "Current RDS grace period days remaining: $grace"
} catch { Write-Output "WARNING: Could not query grace period - $_" }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Win32Api {
    public class NtDll {
        [DllImport("ntdll.dll", EntryPoint="RtlAdjustPrivilege")]
        public static extern int RtlAdjustPrivilege(ulong Privilege, bool Enable, bool CurrentThread, ref bool Enabled);
    }
}
"@

$enabled = $false
[void][Win32Api.NtDll]::RtlAdjustPrivilege(9, $true, $false, [ref]$enabled)

$regPath = "SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod"
$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
    $regPath,
    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
    [System.Security.AccessControl.RegistryRights]::TakeOwnership)
if (-not $key) { throw "Registry key not found: HKLM:\$regPath" }

$acl = $key.GetAccessControl()
$acl.SetOwner([System.Security.Principal.NTAccount]"Administrators")
$key.SetAccessControl($acl)
$rule = New-Object System.Security.AccessControl.RegistryAccessRule("Administrators","FullControl","Allow")
$acl.SetAccessRule($rule)
$key.SetAccessControl($acl)

Remove-Item "HKLM:\$regPath" -Recurse -Force
Write-Output "Grace period registry key deleted. Reset to 120 days."

try {
    $tsSetting = Get-WmiObject -Namespace root\cimv2\terminalservices -Class Win32_TerminalServiceSetting
    $gracePost = (Invoke-WmiMethod -Path $tsSetting.__PATH -Name GetGracePeriodDays).DaysLeft
    Write-Output "Post-reset RDS grace period days remaining: $gracePost"
} catch { Write-Output "WARNING: Could not verify grace period - will confirm after reboot." }

Write-Output "Forcing reboot in 5 seconds..."
shutdown /r /f /t 5
'''

SSM_DOC = {
    "schemaVersion": "2.2",
    "description": "Reset RDS Grace Licensing Period to 120 days and force reboot.",
    "mainSteps": [{
        "action": "aws:runPowerShellScript",
        "name": "ResetRDSGracePeriod",
        "inputs": {"runCommand": [SCRIPT_CONTENT]}
    }]
}

VERIFY_SCRIPT = r'''
try {
    $ts = Get-WmiObject -Namespace root\cimv2\terminalservices -Class Win32_TerminalServiceSetting
    $d = (Invoke-WmiMethod -Path $ts.__PATH -Name GetGracePeriodDays).DaysLeft
    Write-Output "RDS_GRACE_DAYS=$d"
} catch { Write-Output "RDS_GRACE_DAYS=ERROR: $_" }
'''


# =============================================================================
# Auth
# =============================================================================
def sso_login():
    """Check SSO session; if expired, open browser for login."""
    print("Checking SSO session...", end=" ")
    try:
        session = boto3.Session(profile_name=AWS_PROFILE)
        sts = session.client("sts")
        identity = sts.get_caller_identity()
        print(f"OK — {identity['Arn']}")
    except Exception:
        print("expired.")
        print("Opening browser for SSO login...")
        ret = subprocess.run(["aws", "sso", "login", "--sso-session", SSO_SESSION])
        if ret.returncode != 0:
            print("SSO login failed."); sys.exit(1)
        print("SSO login successful.")


def get_client(service, region):
    return boto3.Session(profile_name=AWS_PROFILE, region_name=region).client(service)


# =============================================================================
# SSM Document
# =============================================================================
def ensure_document(region):
    ssm = get_client("ssm", region)
    try:
        ssm.describe_document(Name=DOC_NAME)
        print(f"  SSM document '{DOC_NAME}' exists in {region}.")
    except ssm.exceptions.InvalidDocument:
        print(f"  Creating SSM document '{DOC_NAME}' in {region}...")
        ssm.create_document(
            Content=json.dumps(SSM_DOC), Name=DOC_NAME,
            DocumentType="Command", DocumentFormat="JSON",
        )
        print("  Created.")


# =============================================================================
# EC2 Discovery
# =============================================================================
def find_instances(client_code, region):
    ec2 = get_client("ec2", region)
    resp = ec2.describe_instances(Filters=[
        {"Name": "tag:Name", "Values": [
            f"{client_code}-*TRKRD*", f"{client_code}-*trkrd*",
            f"{client_code}*TRKRD*", f"{client_code}*trkrd*",
        ]},
        {"Name": "instance-state-name", "Values": ["running", "stopped"]},
    ])
    out = []
    for res in resp["Reservations"]:
        for i in res["Instances"]:
            name = next((t["Value"] for t in i.get("Tags", []) if t["Key"] == "Name"), "N/A")
            out.append({
                "InstanceId": i["InstanceId"], "Name": name,
                "State": i["State"]["Name"],
                "PrivateIp": i.get("PrivateIpAddress", "N/A"),
                "Region": region,
            })
    return out


def display_instances(instances):
    print(f"\n{'#':<4} {'Name':<30} {'Instance ID':<22} {'State':<10} {'Private IP':<16} {'Region'}")
    print("-" * 110)
    for i, inst in enumerate(instances, 1):
        print(f"{i:<4} {inst['Name']:<30} {inst['InstanceId']:<22} {inst['State']:<10} {inst['PrivateIp']:<16} {inst['Region']}")


# =============================================================================
# SSM Execution
# =============================================================================
def run_reset(region, instance_ids):
    ssm = get_client("ssm", region)
    print(f"\nSending reset command to {instance_ids} in {region}...")
    resp = ssm.send_command(
        InstanceIds=instance_ids, DocumentName=DOC_NAME,
        TimeoutSeconds=120, Comment="RDS License Grace Period Reset",
    )
    cmd_id = resp["Command"]["CommandId"]
    print(f"Command ID: {cmd_id}")

    for iid in instance_ids:
        print(f"\nWaiting for command on {iid}...")
        try:
            ssm.get_waiter("command_executed").wait(
                CommandId=cmd_id, InstanceId=iid,
                WaiterConfig={"Delay": 5, "MaxAttempts": 30},
            )
        except Exception:
            pass  # instance reboots mid-command
        try:
            out = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=iid)
            print(f"  Status: {out['Status']}")
            if out.get("StandardOutputContent"):
                print(f"  Output: {out['StandardOutputContent'].strip()}")
            if out.get("StandardErrorContent"):
                print(f"  Errors: {out['StandardErrorContent'].strip()}")
        except Exception as e:
            print(f"  Could not retrieve output (instance likely rebooting): {e}")
    return cmd_id


# =============================================================================
# Wait & Verify
# =============================================================================
def ping_until_online(ip, timeout=300):
    print(f"\nPinging {ip} until online (timeout {timeout}s)...")
    start = time.time()
    while time.time() - start < timeout:
        ret = subprocess.call(
            ["ping", "-n", "1", "-w", "1000", ip],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if ret == 0:
            print(f"  {ip} is ONLINE.")
            return True
        time.sleep(3)
    print(f"  TIMEOUT: {ip} not reachable within {timeout}s.")
    return False


def wait_ssm_online(region, instance_id, timeout=300):
    ssm = get_client("ssm", region)
    print(f"Waiting for SSM agent on {instance_id}...")
    start = time.time()
    while time.time() - start < timeout:
        try:
            resp = ssm.describe_instance_information(
                Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
            )
            info = resp.get("InstanceInformationList", [])
            if info and info[0].get("PingStatus") == "Online":
                print(f"  SSM agent on {instance_id} is Online.")
                return True
        except Exception:
            pass
        time.sleep(5)
    print(f"  TIMEOUT: SSM agent not online within {timeout}s.")
    return False


def verify_license(region, instance_id):
    ssm = get_client("ssm", region)
    print(f"\nVerifying license on {instance_id}...")
    resp = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunPowerShellScript",
        Parameters={"commands": [VERIFY_SCRIPT]},
        TimeoutSeconds=60,
    )
    cmd_id = resp["Command"]["CommandId"]
    time.sleep(10)
    try:
        out = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
        stdout = out.get("StandardOutputContent", "")
        print(f"  {stdout.strip()}")
    except Exception as e:
        print(f"  Verification failed: {e}")


# =============================================================================
# Main
# =============================================================================
def main():
    # 0. SSO login (opens browser if expired)
    sso_login()

    # 1. Client code
    client_code = input("\nEnter client code (e.g. ARCT): ").strip().upper()
    if not client_code:
        print("Client code is required."); sys.exit(1)

    # 2. Region
    r = input("Region — [E]ast / [W]est / [Enter] for both: ").strip().lower()
    search_regions = [REGIONS[r]] if r in REGIONS else list(REGIONS.values())

    # 3. Ensure SSM doc
    for reg in search_regions:
        ensure_document(reg)

    # 4. Find instances
    all_inst = []
    for reg in search_regions:
        print(f"\nSearching for '{client_code}' TRKRD instances in {reg}...")
        found = find_instances(client_code, reg)
        print(f"  Found {len(found)} instance(s).")
        all_inst.extend(found)

    if not all_inst:
        print("\nNo matching instances found."); sys.exit(0)

    display_instances(all_inst)

    # 5. Select
    sel = input("\nSelect instance(s) by number (comma-separated, e.g. 1,3): ").strip()
    indices = [int(x.strip()) - 1 for x in sel.split(",") if x.strip().isdigit()]
    selected = [all_inst[i] for i in indices if 0 <= i < len(all_inst)]
    if not selected:
        print("No valid selection."); sys.exit(1)

    print("\nSelected:")
    for s in selected:
        print(f"  {s['Name']} ({s['InstanceId']}) — {s['Region']}")

    # 6. Execute by region
    by_region = {}
    for s in selected:
        by_region.setdefault(s["Region"], []).append(s)

    for region, insts in by_region.items():
        ids = [i["InstanceId"] for i in insts]
        run_reset(region, ids)

        for inst in insts:
            ip, iid = inst["PrivateIp"], inst["InstanceId"]
            if ip and ip != "N/A":
                ping_until_online(ip)
            wait_ssm_online(region, iid)
            verify_license(region, iid)

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
