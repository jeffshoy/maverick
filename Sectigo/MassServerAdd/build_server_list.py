#!/usr/bin/env python3
"""Build a Sectigo server-add JSON file from EC2 instances in one AWS account.

Queries EC2 across one or more regions, filters running instances whose Name
tag matches any of the specified substrings, and writes a JSON array ready for
add_servers_to_agent.py.

All servers are registered as:
  vendor:         IIS
  connectionType: REMOTE_LEGACY_NATIVE_API

The service-account password is never passed on the command line. Supply it
via one of two methods:

  --password-env VAR_NAME
      Read from an environment variable you set in your terminal session.
      Set it just before running, unset it after. Never use $env:VAR=... in
      a command you save to a file or script.

        $env:SECTIGO_SVC_PASSWORD = "from-your-password-manager"
        python build_server_list.py ... --password-env SECTIGO_SVC_PASSWORD
        Remove-Item Env:SECTIGO_SVC_PASSWORD

  --ssm-password-param /path/to/param
      Retrieve a SecureString from AWS SSM Parameter Store (requires
      ssm:GetParameter permission in the target account).

The output JSON file DOES contain the plaintext password (required by
add_servers_to_agent.py) — delete it immediately after the import completes.

Usage:
  # Dry-run first — no file written, no credentials retrieved:
  python build_server_list.py --profile PALegacyFinEntANCO --domain corp.local \\
      --username svc-sectigo --password-env SECTIGO_SVC_PASSWORD --dry-run

  # Generate the JSON:
  python build_server_list.py --profile PALegacyFinEntANCO --domain corp.local \\
      --username svc-sectigo --password-env SECTIGO_SVC_PASSWORD \\
      --output servers_account1.json

  python add_servers_to_agent.py --agent-id 42 servers_account1.json --dry-run
  python add_servers_to_agent.py --agent-id 42 servers_account1.json
  del servers_account1.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from typing import Any

import boto3
from botocore.exceptions import ClientError, NoCredentialsError, ProfileNotFound


DEFAULT_NAME_FILTERS = ["onsjb", "onsap", "onsrp", "onsol", "pxsf", "trkwb", "etawb"]
DEFAULT_REGIONS = ["us-east-1", "us-east-2", "us-west-1", "us-west-2"]

VENDOR = "IIS"
CONNECTION_TYPE = "REMOTE_LEGACY_NATIVE_API"


def get_ssm_parameter(session: boto3.Session, param_name: str) -> str:
    """Retrieve a SecureString parameter from SSM Parameter Store."""
    ssm = session.client("ssm")
    try:
        resp = ssm.get_parameter(Name=param_name, WithDecryption=True)
        return resp["Parameter"]["Value"]
    except ClientError as e:
        code = e.response["Error"]["Code"]
        msg = e.response["Error"]["Message"]
        sys.exit(f"Failed to retrieve SSM parameter '{param_name}': {code} — {msg}")


def verify_credentials(session: boto3.Session, profile: str) -> str:
    """Verify AWS credentials and return the account ID, or exit on failure."""
    try:
        identity = session.client("sts").get_caller_identity()
        return identity["Account"]
    except NoCredentialsError:
        sys.exit(
            f"No credentials found for profile '{profile}'. "
            f"Run: aws sso login --profile {profile}"
        )
    except ClientError as e:
        sys.exit(f"Failed to verify AWS credentials: {e}")


def discover_instances(
    session: boto3.Session,
    region: str,
    name_filters: list[str],
) -> list[dict[str, Any]]:
    """Return running EC2 instances whose Name tag contains any filter substring."""
    ec2 = session.client("ec2", region_name=region)
    paginator = ec2.get_paginator("describe_instances")
    pages = paginator.paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
    )

    matches: list[dict[str, Any]] = []
    for page in pages:
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                name_tag = next(
                    (t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"),
                    "",
                )
                if not any(f.lower() in name_tag.lower() for f in name_filters):
                    continue
                matches.append(
                    {
                        "name_tag": name_tag,
                        "instance_id": inst["InstanceId"],
                        "private_dns": inst.get("PrivateDnsName", ""),
                        "private_ip": inst.get("PrivateIpAddress", ""),
                        "region": region,
                    }
                )
    return matches


def build_server_entry(
    instance: dict[str, Any],
    domain: str,
    use_private_dns: bool,
    username: str,
    password: str,
    store_name: str | None,
) -> dict[str, Any]:
    """Convert an EC2 instance dict to a Sectigo server registration payload."""
    fqdn = f"{instance['name_tag']}.{domain.lower()}"

    if use_private_dns:
        ip = instance["private_dns"] or instance["private_ip"]
    else:
        # Default: use the FQDN as the DNS hostname — works for AD-joined Windows
        # servers where the Name tag matches the computer name in DNS.
        ip = fqdn

    if not ip:
        sys.exit(
            f"Instance {instance['instance_id']} ({instance['name_tag']}) has no "
            "DNS hostname or private IP — cannot build server entry."
        )

    entry: dict[str, Any] = {
        "name": fqdn,
        "vendor": VENDOR,
        "connectionType": CONNECTION_TYPE,
        "ip": ip,
        "username": username,
        "password": password,
    }
    if store_name:
        entry["storeName"] = store_name

    return entry


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=(
            "Discover EC2 instances and build a Sectigo server-add JSON file. "
            "Output is ready for: python add_servers_to_agent.py --agent-id <id> <output>"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Required AWS permissions:\n"
            "  ec2:DescribeInstances, sts:GetCallerIdentity\n"
            "  (+ ssm:GetParameter if using --ssm-password-param)\n\n"
            "The output JSON contains plaintext credentials. Delete it after import."
        ),
    )
    p.add_argument(
        "--profile",
        required=True,
        help="AWS SSO profile name from ~/.aws/config.",
    )
    p.add_argument(
        "--domain",
        required=True,
        help="Active Directory domain for FQDN construction, e.g. corp.local",
    )
    p.add_argument(
        "--username",
        required=True,
        help="Sectigo service account username for IIS connections.",
    )

    pw_group = p.add_mutually_exclusive_group(required=True)
    pw_group.add_argument(
        "--password-env",
        metavar="VAR_NAME",
        help=(
            "Name of an environment variable that holds the service account password. "
            "Set it in your terminal before running, unset it after. "
            "Example: --password-env SECTIGO_SVC_PASSWORD"
        ),
    )
    pw_group.add_argument(
        "--ssm-password-param",
        metavar="SSM_PARAM_PATH",
        help="SSM Parameter Store SecureString path for the service account password.",
    )
    p.add_argument(
        "--regions",
        default=",".join(DEFAULT_REGIONS),
        help=(
            f"Comma-separated regions to search "
            f"(default: {','.join(DEFAULT_REGIONS)})."
        ),
    )
    p.add_argument(
        "--name-filters",
        default=",".join(DEFAULT_NAME_FILTERS),
        help=(
            "Comma-separated substrings matched against EC2 Name tags "
            f"(default: {','.join(DEFAULT_NAME_FILTERS)})."
        ),
    )
    p.add_argument(
        "--use-private-dns",
        action="store_true",
        help=(
            "Use the EC2 private DNS name for the 'ip' field instead of the FQDN. "
            "Default is to use the FQDN (<Name-tag>.<domain>)."
        ),
    )
    p.add_argument(
        "--store-name",
        default=None,
        metavar="CERT_STORE",
        help=(
            "Optional Windows certificate store name (storeName field), "
            "e.g. 'MY' or 'WebHosting'. Omit to use Sectigo's default."
        ),
    )
    p.add_argument(
        "--output-prefix",
        default=None,
        metavar="PREFIX",
        help=(
            "Filename prefix for the output JSON files. One file is written per "
            "region that has matches, e.g. PREFIX_us-east-1.json. "
            "Required unless --dry-run is set."
        ),
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Print matching instances without writing a file or "
            "resolving the password."
        ),
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()

    if not args.dry_run and not args.output_prefix:
        sys.exit("--output-prefix is required unless --dry-run is specified.")

    regions = [r.strip() for r in args.regions.split(",") if r.strip()]
    name_filters = [f.strip() for f in args.name_filters.split(",") if f.strip()]

    if not regions:
        sys.exit("--regions must specify at least one region.")
    if not name_filters:
        sys.exit("--name-filters must specify at least one filter substring.")

    try:
        session = boto3.Session(profile_name=args.profile)
    except ProfileNotFound:
        sys.exit(
            f"AWS profile '{args.profile}' not found in ~/.aws/config. "
            "Run 'aws configure list-profiles' to see available profiles."
        )

    account_id = verify_credentials(session, args.profile)
    print(f"Account : {account_id}")
    print(f"Profile : {args.profile}")
    print(f"Domain  : {args.domain}")
    print(f"Filters : {', '.join(name_filters)}")
    print(f"Regions : {', '.join(regions)}")
    print()

    # Discover matching instances across all requested regions.
    all_instances: list[dict[str, Any]] = []
    for region in regions:
        print(f"  Scanning {region}...", end=" ", flush=True)
        try:
            found = discover_instances(session, region, name_filters)
            print(f"{len(found)} match(es)")
            all_instances.extend(found)
        except ClientError as e:
            print(f"ERROR — {e}")

    print()

    if not all_instances:
        print(
            f"No running instances matched filters {name_filters} "
            f"in account {account_id}."
        )
        sys.exit(0)

    print(f"Found {len(all_instances)} matching instance(s):")
    col_w = max(len(i["name_tag"]) for i in all_instances) + 2
    for inst in sorted(all_instances, key=lambda x: x["name_tag"]):
        print(
            f"  {inst['name_tag']:<{col_w}}"
            f"  {inst['instance_id']}  {inst['region']}"
        )

    if args.dry_run:
        print(
            f"\n[dry-run] {len(all_instances)} server(s) would be written to JSON. "
            "Re-run without --dry-run (and with --output) to generate the file."
        )
        return

    # Resolve password only when actually writing — keeps dry-runs credential-free.
    if args.password_env:
        password = os.environ.get(args.password_env, "")
        if not password:
            sys.exit(
                f"Environment variable '{args.password_env}' is not set or is empty. "
                f"Set it in your terminal before running:\n"
                f"  PowerShell: $env:{args.password_env} = 'your-password'\n"
                f"  bash/cmd:   set {args.password_env}=your-password"
            )
        print(f"\nPassword read from environment variable: {args.password_env}")
    else:
        print(f"\nRetrieving service account password from SSM: {args.ssm_password_param}")
        password = get_ssm_parameter(session, args.ssm_password_param)
        print("  Retrieved.")

    # Group by region so each output file targets a single network agent.
    by_region: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for inst in sorted(all_instances, key=lambda x: x["name_tag"]):
        entry = build_server_entry(
            inst,
            args.domain,
            args.use_private_dns,
            args.username,
            password,
            args.store_name,
        )
        by_region[inst["region"]].append(entry)

    output_files: list[str] = []
    for region, servers in sorted(by_region.items()):
        out_path = f"{args.output_prefix}_{region}.json"
        with open(out_path, "w", encoding="utf-8") as fh:
            json.dump(servers, fh, indent=2)
        output_files.append(out_path)
        print(f"  Wrote {len(servers)} server(s) to: {out_path}")

    print()
    print("Next steps (run for each output file):")
    print(
        "  Dry-run:   python add_servers_to_agent.py --agent-id <id> <file> --dry-run"
    )
    print(
        "  Live:      python add_servers_to_agent.py --agent-id <id> <file>"
    )
    print(
        "  Clean up:  Remove-Item <file>   # contains plaintext credentials"
    )
    print()
    print("Agent IDs:  us-east-1 → 18227   |   us-west-2 → 18247")


if __name__ == "__main__":
    main()
