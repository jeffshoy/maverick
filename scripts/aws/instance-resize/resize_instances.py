"""
EC2 Instance Type Resize Tool
Stop instances, change their type to the Compute Optimizer recommendation, then start
them back up in dependency order (ASAv → DC → DB → App/Job → Web/Online/Storefront).

Usage:
    python resize_instances.py [--dry-run] [--account OCLS|SANA|all]

Requires: pip install boto3
"""

import argparse
import os
import sys
import time
from datetime import datetime

import boto3

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from aws_sso_helper import resolve_account, ensure_profile_session

REGION = "us-east-1"

# ---------------------------------------------------------------------------
# Resize targets
# Each entry: (instance_name, current_type, recommended_type, app_role, no_resize)
# no_resize=True: instance is included in the stop/start cycle but AWS blocks
#   modify_instance_attribute on it (e.g. Cisco ASAv — Marketplace product).
# app_role drives startup ordering — see STARTUP_ORDER below.
# ---------------------------------------------------------------------------

OCLS_TARGETS = [
    # Production
    ("OCLS-ASAv",       "c5.4xlarge",  "r5.xlarge",      "asav",   True),
    ("OCLS-PCTXSA001",  "m6a.xlarge",  "r6a.large",      "xenapp", False),
    ("OCLS-PCTXSA002",  "m6a.xlarge",  "r6a.large",      "xenapp", False),
    ("OCLS-PONSAP001",  "m6a.xlarge",  "r6a.large",      "app",    False),
    ("OCLS-PONSDB001",  "m6a.xlarge",  "r6a.large",      "db",     False),
    ("OCLS-PONSJB001",  "m6a.xlarge",  "r6a.large",      "app",    False),
    ("OCLS-PONSOL001",  "m6a.large",   "r7a.medium",     "web",    False),
    ("OCLS-PXSF001",    "m6a.xlarge",  "r7a.large",      "web",    False),
    # Test
    ("OCLS-TCTXSA001",  "t3a.xlarge",  "r6a.large",      "xenapp", False),
    ("OCLS-TONSAP001",  "t3a.xlarge",  "r6a.large",      "app",    False),
    ("OCLS-TONSJB001",  "t3a.xlarge",  "r6a.large",      "app",    False),
]

SANA_TARGETS = [
    # Production
    ("SANA-ASAv",       "c5.4xlarge",  "r5.xlarge",      "asav",   True),
    ("SANA-PDC001",     "m5.large",    "m7i-flex.large", "dc",     False),
    ("SANA-PONSOL001",  "m6a.xlarge",  "r6a.large",      "web",    False),
    ("SANA-PRDS001",    "m6a.large",   "r7a.medium",     "web",    False),
    # Test
    ("SANA-TONSOL001",  "t3a.large",   "r7a.medium",     "web",    False),
]

# Startup groups in order — instances within a group start concurrently,
# and the script waits for the group to reach 'running' before the next.
STARTUP_ORDER = ["asav", "dc", "db", "app", "xenapp", "web"]

POLL_INTERVAL = 15   # seconds between state polls
STOP_TIMEOUT  = 300  # seconds max to wait for stopped
START_TIMEOUT = 300  # seconds max to wait for running


def ts():
    return datetime.now().strftime("%H:%M:%S")


def log(msg):
    print(f"[{ts()}] {msg}", flush=True)


def find_instance_id(ec2, name):
    """Return the instance ID for an EC2 instance matching the Name tag."""
    resp = ec2.describe_instances(Filters=[
        {"Name": "tag:Name", "Values": [name]},
        {"Name": "instance-state-name",
         "Values": ["running", "stopped", "stopping", "pending"]},
    ])
    instances = [
        inst
        for r in resp["Reservations"]
        for inst in r["Instances"]
    ]
    if not instances:
        raise RuntimeError(f"No instance found with Name='{name}'")
    if len(instances) > 1:
        raise RuntimeError(
            f"Multiple instances found with Name='{name}': "
            + ", ".join(i["InstanceId"] for i in instances)
        )
    inst = instances[0]
    return inst["InstanceId"], inst["InstanceType"], inst["State"]["Name"]


def wait_for_state(ec2, instance_id, name, target_state, timeout):
    """Poll until the instance reaches target_state or timeout expires."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        state = resp["Reservations"][0]["Instances"][0]["State"]["Name"]
        if state == target_state:
            return True
        log(f"  {name} ({instance_id}): state={state}, waiting for {target_state}...")
        time.sleep(POLL_INTERVAL)
    return False


def resize_account(account_name, targets, dry_run):
    log(f"=== {account_name} ===")

    acct = resolve_account(account_name)
    session = ensure_profile_session(acct["profile"], acct["ssoSession"])
    ec2 = session.client("ec2", region_name=REGION)

    # --- Resolve instance IDs ---
    log("Resolving instance IDs...")
    resolved = []
    for name, current_type, rec_type, role, no_resize in targets:
        try:
            iid, actual_type, state = find_instance_id(ec2, name)
            log(f"  {name}: {iid} ({actual_type}, {state})")
            if actual_type != current_type and not no_resize:
                log(f"  WARNING: {name} actual type {actual_type} != expected {current_type}")
            resolved.append((name, iid, actual_type, rec_type, role, state, no_resize))
        except RuntimeError as e:
            log(f"  ERROR: {e}")
            sys.exit(1)

    if dry_run:
        log("\n[DRY RUN] Would perform the following changes:")
        for name, iid, current, rec, role, state, no_resize in resolved:
            if no_resize:
                log(f"  SKIP  {name}: Marketplace instance — type change not supported by AWS")
            elif current == rec:
                log(f"  SKIP  {name}: already {rec}")
            else:
                log(f"  RESIZE {name}: {current} -> {rec}  (role={role})")
        log("[DRY RUN] No changes made.\n")
        return

    # --- Stop all instances that need a type change or are no_resize and not stopped ---
    # no_resize instances must still stop/start so the rest of the fleet comes up in order.
    needs_work = [
        (name, iid, current, rec, role, no_resize)
        for name, iid, current, rec, role, state, no_resize in resolved
        if no_resize or current != rec
    ]
    to_stop = [
        (name, iid, current, rec, role, no_resize)
        for name, iid, current, rec, role, state, no_resize in resolved
        if (no_resize or current != rec) and state != "stopped"
    ]
    already_stopped = [
        (name, iid, current, rec, role, no_resize)
        for name, iid, current, rec, role, state, no_resize in resolved
        if (no_resize or current != rec) and state == "stopped"
    ]

    for name, iid, current, rec, role, _ in [
        r for r in [
            (name, iid, current, rec, role, no_resize)
            for name, iid, current, rec, role, state, no_resize in resolved
            if not no_resize and current == rec
        ]
    ]:
        log(f"  SKIP {name}: type already matches recommendation")

    if to_stop:
        log(f"\nStopping {len(to_stop)} instance(s)...")
        stop_ids = [iid for _, iid, _, _, _, _ in to_stop]
        ec2.stop_instances(InstanceIds=stop_ids)

        for name, iid, current, rec, role, no_resize in to_stop:
            log(f"  Waiting for {name} ({iid}) to stop...")
            if not wait_for_state(ec2, iid, name, "stopped", STOP_TIMEOUT):
                log(f"  ERROR: {name} did not reach 'stopped' within {STOP_TIMEOUT}s. Aborting.")
                sys.exit(1)
            log(f"  {name}: stopped.")

    all_to_process = to_stop + already_stopped

    # --- Change instance types (skip Marketplace instances) ---
    resizable = [(name, iid, current, rec, role) for name, iid, current, rec, role, no_resize in all_to_process if not no_resize]
    skipped   = [(name, iid, current, rec, role) for name, iid, current, rec, role, no_resize in all_to_process if no_resize]

    if resizable:
        log(f"\nChanging instance types for {len(resizable)} instance(s)...")
        for name, iid, current, rec, role in resizable:
            log(f"  {name}: {current} -> {rec}")
            ec2.modify_instance_attribute(
                InstanceId=iid,
                InstanceType={"Value": rec},
            )
            log(f"  {name}: type set to {rec}")

    for name, iid, current, rec, role in skipped:
        log(f"  SKIP resize {name}: Marketplace instance — will start as-is ({current})")

    # --- Start instances in role order ---
    by_role = {}
    for name, iid, current, rec, role, no_resize in all_to_process:
        by_role.setdefault(role, []).append((name, iid))

    log("\nStarting instances in dependency order...")
    for role in STARTUP_ORDER:
        group = by_role.get(role, [])
        if not group:
            continue
        names = [n for n, _ in group]
        ids   = [i for _, i in group]
        log(f"\n  Starting group '{role}': {', '.join(names)}")
        ec2.start_instances(InstanceIds=ids)

        for name, iid in group:
            log(f"  Waiting for {name} ({iid}) to reach 'running'...")
            if not wait_for_state(ec2, iid, name, "running", START_TIMEOUT):
                log(f"  ERROR: {name} did not reach 'running' within {START_TIMEOUT}s. Aborting.")
                sys.exit(1)
            log(f"  {name}: running.")

        log(f"  Group '{role}' fully online.")

    log(f"\n=== {account_name} complete ===\n")


def main():
    parser = argparse.ArgumentParser(
        description="Resize EC2 instances per Compute Optimizer recommendations."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would happen; make no API calls.",
    )
    parser.add_argument(
        "--account",
        choices=["OCLS", "SANA", "all"],
        default="all",
        help="Which account to process (default: all).",
    )
    args = parser.parse_args()

    if args.dry_run:
        print("*** DRY RUN MODE — no changes will be made ***\n")

    accounts = []
    if args.account in ("OCLS", "all"):
        accounts.append(("PALegacyFinEntOCLS", OCLS_TARGETS))
    if args.account in ("SANA", "all"):
        accounts.append(("PALegacyFinEntSANA", SANA_TARGETS))

    for account_name, targets in accounts:
        resize_account(account_name, targets, args.dry_run)

    print("All done.")


if __name__ == "__main__":
    main()
