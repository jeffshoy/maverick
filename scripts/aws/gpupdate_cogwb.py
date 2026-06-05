"""
One-shot gpupdate /force across all *cogwb* instances in PALegacyAnalytics.
Batches SSM send_command in groups of 50, polls until all invocations settle,
then prints a success/failure summary.
"""

import boto3
import sys
import time

PROFILE = "PALegacyAnalytics"
REGIONS = ["us-east-1", "us-west-2"]
NAME_FILTER = "cogwb"
COMMAND = "gpupdate /force"
SSM_TIMEOUT = 300   # seconds before SSM marks the invocation timed-out
POLL_INTERVAL = 15  # seconds between status polls
MAX_WAIT = 600      # hard ceiling on total poll time

TERMINAL = {"Success", "Failed", "TimedOut", "Cancelled", "DeliveryTimedOut"}


def collect_instances():
    all_instances = {}
    for region in REGIONS:
        session = boto3.Session(profile_name=PROFILE, region_name=region)
        ec2 = session.client("ec2")
        paginator = ec2.get_paginator("describe_instances")
        pages = paginator.paginate(
            Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
        )
        matches = []
        for page in pages:
            for res in page["Reservations"]:
                for inst in res["Instances"]:
                    name = next(
                        (t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), ""
                    )
                    if NAME_FILTER.lower() in name.lower():
                        matches.append({"id": inst["InstanceId"], "name": name})
        all_instances[region] = matches
        print(f"  {region}: {len(matches)} instances matched", flush=True)
    return all_instances


def send_commands(all_instances):
    """Send SSM commands in batches of 50. Returns cmd_map keyed by command ID."""
    cmd_map = {}
    for region, instances in all_instances.items():
        if not instances:
            continue
        session = boto3.Session(profile_name=PROFILE, region_name=region)
        ssm = session.client("ssm")
        ids = [i["id"] for i in instances]
        id_to_name = {i["id"]: i["name"] for i in instances}

        for batch_num, start in enumerate(range(0, len(ids), 50), 1):
            batch_ids = ids[start : start + 50]
            resp = ssm.send_command(
                InstanceIds=batch_ids,
                DocumentName="AWS-RunPowerShellScript",
                Parameters={"commands": [COMMAND]},
                TimeoutSeconds=SSM_TIMEOUT,
            )
            cmd_id = resp["Command"]["CommandId"]
            cmd_map[cmd_id] = {
                "region": region,
                "ssm": ssm,
                "id_to_name": {iid: id_to_name[iid] for iid in batch_ids},
            }
            print(
                f"  [{region}] Batch {batch_num}: CommandId={cmd_id} ({len(batch_ids)} instances)",
                flush=True,
            )
    return cmd_map


def poll_results(cmd_map, total):
    """Poll SSM until all invocations reach a terminal state. Returns {instance_id: status}."""
    results = {}
    pending = set(cmd_map.keys())
    deadline = time.time() + MAX_WAIT

    while pending and time.time() < deadline:
        time.sleep(POLL_INTERVAL)
        still_pending = set()

        for cmd_id in pending:
            data = cmd_map[cmd_id]
            ssm = data["ssm"]
            try:
                paginator = ssm.get_paginator("list_command_invocations")
                invocations = [
                    inv
                    for page in paginator.paginate(CommandId=cmd_id)
                    for inv in page["CommandInvocations"]
                ]
                for inv in invocations:
                    results[inv["InstanceId"]] = inv["Status"]

                expected = len(data["id_to_name"])
                settled = sum(
                    1 for iid in data["id_to_name"] if results.get(iid) in TERMINAL
                )
                if settled < expected:
                    still_pending.add(cmd_id)
            except Exception as exc:
                print(f"  Poll error for {cmd_id}: {exc}", flush=True)
                still_pending.add(cmd_id)

        pending = still_pending
        completed = sum(1 for s in results.values() if s in TERMINAL)
        print(f"  {completed}/{total} settled...", flush=True)

    return results


def main():
    print(f"Collecting *{NAME_FILTER}* running instances in PALegacyAnalytics...")
    all_instances = collect_instances()
    total = sum(len(v) for v in all_instances.values())
    print(f"Total targeted: {total}\n")

    print("Sending SSM commands...")
    cmd_map = send_commands(all_instances)

    print(f"\nPolling for results (up to {MAX_WAIT}s)...")
    results = poll_results(cmd_map, total)

    # Build final report
    success, failures = [], []
    for cmd_id, data in cmd_map.items():
        for iid, name in data["id_to_name"].items():
            status = results.get(iid, "NoResponse")
            if status == "Success":
                success.append(name)
            else:
                failures.append((name, iid, status))

    print("\n=== gpupdate /force — Final Results ===")
    print(f"Success : {len(success)}/{total}")
    print(f"Failed  : {len(failures)}/{total}")
    if failures:
        print("\nNon-success instances:")
        for name, iid, status in sorted(failures):
            print(f"  {name:<25} {iid}  {status}")

    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main()
