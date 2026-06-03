#!/usr/bin/env python3
"""Verify that IIS on each server is actually using the expected Sectigo certificate.

For a given Sectigo certificate ID, this script:
1. Fetches the cert details (CN, thumbprint if available) from Sectigo SCM
2. Fetches the deployment location list (servers + ports) from Sectigo
3. For each unique server:port in the list:
   - Looks up the AWS profile from the renewal CSV (matched by cert CN/SAN)
   - Finds the EC2 instance by Name tag
   - SSMs in and queries IIS SSL bindings
   - Compares the bound cert thumbprint against the expected cert thumbprint
4. Writes a timestamped report CSV

Status values in the report:
  OK                    — bound cert thumbprint matches expected (exact confirmation)
  OK_SUBJECT_MATCH      — thumbprint not available from API; bound cert subject matches expected SAN
  WRONG_CERT            — different cert is bound on that port
  NO_BINDING_ON_PORT_N  — no IIS SSL binding found on that port
  INSTANCE_NOT_FOUND    — EC2 instance not found by Name tag in the account
  SSM_NOT_ONLINE        — instance found but SSM agent is not reachable
  NO_PROFILE            — no AWS profile found in the CSV for this cert's SAN
  SKIP_INVALID_NAME     — location entry is not a real server name (stale Sectigo artifact)

Usage:
  python verify_iis_certs.py --cert-id 15020263
  python verify_iis_certs.py --cert-id 15020263 --debug

Required environment variables (same as other Sectigo scripts):
  SECTIGO_LOGIN, SECTIGO_PASSWORD, SECTIGO_CUSTOMER_URI
Optional:
  SECTIGO_BASE_URL  (default: https://cert-manager.com)
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import boto3
import urllib.error
import urllib.request
from botocore.exceptions import ClientError, NoCredentialsError, ProfileNotFound

SCRIPT_DIR = Path(__file__).parent
CSV_PATH = SCRIPT_DIR / "ASPGOV_SSLCertRenewal_2026-2027.csv"

REGIONS = ["us-east-1", "us-east-2", "us-west-1", "us-west-2"]
SSM_TIMEOUT = 60
SSM_POLL_INTERVAL = 3

# PowerShell: get all IIS SSL bindings with the cert details for each
PS_GET_IIS_BINDINGS = r"""
try {
    Import-Module WebAdministration -ErrorAction Stop
    $bindings = @()
    Get-ChildItem IIS:\SslBindings -ErrorAction SilentlyContinue | ForEach-Object {
        $tp = $_.Thumbprint
        $cert = Get-Item "Cert:\LocalMachine\My\$tp" -ErrorAction SilentlyContinue
        $bindings += [PSCustomObject]@{
            IPAddress  = $_.IPAddress.ToString()
            Port       = [int]$_.Port
            Host       = [string]$_.Host
            Thumbprint = [string]$tp
            Subject    = if ($cert) { $cert.Subject } else { 'NOT_FOUND' }
            NotAfter   = if ($cert) { $cert.NotAfter.ToString('yyyy-MM-dd') } else { '' }
        }
    }
    if ($bindings.Count -eq 0) { Write-Output '[]' } else { $bindings | ConvertTo-Json -Compress }
} catch {
    Write-Output "ERROR: $_"
}
""".strip()


@dataclass(frozen=True)
class Credentials:
    login: str
    password: str
    customer_uri: str
    base_url: str

    @classmethod
    def from_env(cls) -> "Credentials":
        try:
            return cls(
                login=os.environ["SECTIGO_LOGIN"],
                password=os.environ["SECTIGO_PASSWORD"],
                customer_uri=os.environ["SECTIGO_CUSTOMER_URI"],
                base_url=os.environ.get(
                    "SECTIGO_BASE_URL", "https://cert-manager.com"
                ).rstrip("/"),
            )
        except KeyError as missing:
            sys.exit(
                f"Missing required environment variable: {missing.args[0]}. "
                "Set SECTIGO_LOGIN, SECTIGO_PASSWORD, and SECTIGO_CUSTOMER_URI."
            )


def api_get(url: str, creds: Credentials) -> Any:
    req = urllib.request.Request(url, method="GET")
    req.add_header("login", creds.login)
    req.add_header("password", creds.password)
    req.add_header("customerUri", creds.customer_uri)
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        sys.exit(f"HTTP {e.code} from {url}: {body[:500]}")
    except urllib.error.URLError as e:
        sys.exit(f"Network error reaching {url}: {e.reason}")


def get_cert_details(cert_id: int, creds: Credentials) -> dict:
    return api_get(f"{creds.base_url}/api/ssl/v2/{cert_id}", creds)


def get_cert_locations(cert_id: int, creds: Credentials) -> list[dict]:
    candidates = [
        f"{creds.base_url}/api/ssl/v2/{cert_id}/renewalInfo",
        f"{creds.base_url}/api/agent/v1/ssl/{cert_id}/location",
        f"{creds.base_url}/api/ssl/v2/{cert_id}/location",
    ]
    for url in candidates:
        try:
            data = api_get(url, creds)
            if isinstance(data, list) and data:
                return data
            for key in ("locations", "items", "data", "servers"):
                if isinstance(data.get(key), list) and data[key]:
                    return data[key]
        except SystemExit:
            continue
    return []


def load_csv_rows(csv_path: Path) -> list[dict]:
    with open(csv_path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def find_csv_rows_for_cn(cn: str, rows: list[dict]) -> list[dict]:
    """Return CSV rows whose SAN matches this cert CN."""
    cn_normalized = cn.lower().lstrip("*.")
    return [
        row for row in rows
        if row.get("SAN", "").strip().lower().lstrip("*.") == cn_normalized
    ]


def parse_server_name(server_name: str) -> tuple[str, str, str]:
    """Parse 'HOSTNAME.domain.lcl:PORT' into (name_tag, fqdn, port)."""
    if ":" in server_name:
        fqdn, port = server_name.rsplit(":", 1)
    else:
        fqdn, port = server_name, "443"
    name_tag = fqdn.split(".")[0] if "." in fqdn else fqdn
    return name_tag, fqdn, port


def find_instance_by_name(session: boto3.Session, name_tag: str) -> dict | None:
    """Search EC2 across all regions for a running instance with this Name tag."""
    for region in REGIONS:
        try:
            ec2 = session.client("ec2", region_name=region)
            paginator = ec2.get_paginator("describe_instances")
            pages = paginator.paginate(
                Filters=[
                    {"Name": "tag:Name", "Values": [name_tag]},
                    {"Name": "instance-state-name", "Values": ["running"]},
                ]
            )
            for page in pages:
                for res in page["Reservations"]:
                    for inst in res["Instances"]:
                        return {
                            "instance_id": inst["InstanceId"],
                            "region": region,
                            "name_tag": name_tag,
                        }
        except ClientError:
            continue
    return None


def check_ssm_online(session: boto3.Session, region: str, instance_id: str) -> bool:
    ssm = session.client("ssm", region_name=region)
    try:
        resp = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
        )
        info = resp.get("InstanceInformationList", [])
        return bool(info) and info[0].get("PingStatus") == "Online"
    except ClientError:
        return False


def run_ssm_ps(
    session: boto3.Session, region: str, instance_id: str, script: str
) -> str:
    """Run a PowerShell script via SSM Run Command; return stdout or an error string."""
    ssm = session.client("ssm", region_name=region)
    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunPowerShellScript",
            Parameters={"commands": [script]},
            TimeoutSeconds=SSM_TIMEOUT,
        )
    except ClientError as e:
        return f"SSM_SEND_ERROR: {e.response['Error']['Message']}"

    command_id = resp["Command"]["CommandId"]
    deadline = time.time() + SSM_TIMEOUT
    while time.time() < deadline:
        time.sleep(SSM_POLL_INTERVAL)
        try:
            inv = ssm.get_command_invocation(
                CommandId=command_id, InstanceId=instance_id
            )
        except ClientError as e:
            return f"SSM_POLL_ERROR: {e.response['Error']['Message']}"
        s = inv["Status"]
        if s in ("Success", "Failed", "Cancelled", "TimedOut"):
            if s == "Success":
                return inv.get("StandardOutputContent", "").strip()
            return f"SSM_{s}: {inv.get('StandardErrorContent', '').strip()}"
    return "SSM_TIMEOUT"


def get_iis_bindings(
    session: boto3.Session, instance: dict, debug: bool = False
) -> list[dict] | str:
    """Return parsed IIS SSL binding list, or an error string."""
    if not check_ssm_online(session, instance["region"], instance["instance_id"]):
        return "SSM_NOT_ONLINE"

    raw = run_ssm_ps(
        session, instance["region"], instance["instance_id"], PS_GET_IIS_BINDINGS
    )
    if debug:
        print(f"\n    [debug] SSM raw output: {raw[:500]}")

    if raw.startswith("ERROR:") or raw.startswith("SSM_"):
        return raw

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return f"PARSE_ERROR: {raw[:200]}"

    if isinstance(data, dict):
        data = [data]
    return data


def normalize_thumbprint(tp: str) -> str:
    return tp.upper().replace(" ", "").replace(":", "")


def determine_status(
    bindings: list[dict] | str,
    expected_port: str,
    expected_cn: str,
    expected_thumbprint: str | None,
) -> tuple[str, str, str]:
    """Return (status, bound_thumbprint, bound_subject)."""
    if isinstance(bindings, str):
        return bindings, "", ""

    port_int = int(expected_port) if expected_port.isdigit() else None
    port_bindings = [
        b for b in bindings
        if (port_int is not None and b.get("Port") == port_int)
        or str(b.get("Port", "")) == expected_port
    ]

    if not port_bindings:
        other_ports = sorted({str(b.get("Port", "")) for b in bindings})
        return (
            f"NO_BINDING_ON_PORT_{expected_port}",
            "",
            f"(other bound ports: {','.join(other_ports) or 'none'})",
        )

    binding = port_bindings[0]
    bound_tp = normalize_thumbprint(binding.get("Thumbprint") or "")
    bound_subject = binding.get("Subject", "")

    if expected_thumbprint:
        exp_tp = normalize_thumbprint(expected_thumbprint)
        status = "OK" if bound_tp == exp_tp else "WRONG_CERT"
    else:
        # No thumbprint from API — fall back to subject-pattern match
        cn_pattern = expected_cn.lower().lstrip("*.")
        status = (
            "OK_SUBJECT_MATCH"
            if cn_pattern in bound_subject.lower()
            else "WRONG_CERT"
        )

    return status, bound_tp, bound_subject


def pick_session_for_server(
    name_tag: str,
    matching_rows: list[dict],
    profile_sessions: dict[str, boto3.Session],
) -> boto3.Session | None:
    """Return the boto3 session for the account that owns this server."""
    if len(matching_rows) == 1:
        return profile_sessions.get(matching_rows[0]["aws_profile"].strip())

    # Multiple rows with the same SAN (*.aspgov.com) — match via name_filters
    name_lower = name_tag.lower()
    for row in matching_rows:
        filters = [
            f.strip()
            for f in row.get("name_filters", "").split(",")
            if f.strip()
        ]
        if any(f in name_lower for f in filters):
            return profile_sessions.get(row["aws_profile"].strip())
    return None


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Verify IIS SSL bindings match the expected Sectigo certificate.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--cert-id",
        type=int,
        required=True,
        help="Sectigo certificate ID to verify (e.g. 15020263).",
    )
    p.add_argument(
        "--output",
        default=None,
        help=(
            "Output CSV path. Defaults to "
            "verify_iis_certs_<cert_id>_<timestamp>.csv in the current directory."
        ),
    )
    p.add_argument(
        "--debug",
        action="store_true",
        help="Dump raw API responses and SSM output for diagnosis.",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    creds = Credentials.from_env()

    # ── 1. Cert details ──────────────────────────────────────────────────────
    print(f"Fetching certificate {args.cert_id} from Sectigo...")
    cert = get_cert_details(args.cert_id, creds)
    if args.debug:
        print("\n--- Cert details (raw) ---")
        print(json.dumps(cert, indent=2))

    cn = cert.get("commonName", "")
    cert_status = cert.get("status", "")
    thumbprint = next(
        (
            cert.get(f)
            for f in ("thumbprint", "sha1Hash", "sha1Fingerprint", "sha1", "fingerprint")
            if cert.get(f)
        ),
        "",
    )

    print(f"  CN         : {cn}")
    print(f"  Status     : {cert_status}")
    print(
        f"  Thumbprint : {thumbprint or '(not returned by API — will use subject match)'}"
    )

    # ── 2. Location list ─────────────────────────────────────────────────────
    print("\nFetching deployment locations...")
    locations = get_cert_locations(args.cert_id, creds)
    if args.debug:
        print("\n--- Locations (raw) ---")
        print(json.dumps(locations, indent=2))

    if not locations:
        print(
            "No locations returned. Re-run with --debug to inspect the raw response.\n"
            "The location data may be embedded in the cert details above."
        )
        sys.exit(0)

    # Deduplicate by server_name (same server:port can appear multiple times
    # when both old and new agents are registered)
    unique_targets: dict[str, str] = {}
    for loc in locations:
        sn = (
            loc.get("name") or loc.get("serverName") or loc.get("hostname") or ""
        ).strip()
        if sn:
            unique_targets[sn] = sn

    print(
        f"Found {len(locations)} location record(s), "
        f"{len(unique_targets)} unique server:port target(s)."
    )

    # ── 3. CSV lookup ─────────────────────────────────────────────────────────
    print("\nLooking up AWS profile(s) from renewal CSV...")
    csv_rows = load_csv_rows(CSV_PATH)
    matching_rows = find_csv_rows_for_cn(cn, csv_rows)

    if not matching_rows:
        print(
            f"  WARNING: No CSV row found for SAN '{cn}'.\n"
            "           Cannot determine AWS profile — all servers will report NO_PROFILE."
        )
    else:
        print(f"  Matched row(s): {[r['aws_profile'] for r in matching_rows]}")

    # Authenticate each profile once upfront
    profile_sessions: dict[str, boto3.Session] = {}
    for row in matching_rows:
        profile = row["aws_profile"].strip()
        if profile in profile_sessions:
            continue
        try:
            session = boto3.Session(profile_name=profile)
            session.client("sts").get_caller_identity()
            profile_sessions[profile] = session
        except ProfileNotFound:
            print(f"  WARNING: AWS profile '{profile}' not found.")
        except (NoCredentialsError, ClientError) as e:
            print(f"  WARNING: Auth failed for profile '{profile}': {e}")

    # ── 4. Check each server ──────────────────────────────────────────────────
    print(f"\nChecking {len(unique_targets)} server:port target(s)...\n")

    fieldnames = [
        "cert_id", "cert_cn", "server_name", "port",
        "expected_thumbprint", "status",
        "bound_thumbprint", "bound_subject",
        "instance_id", "region",
    ]
    results: list[dict] = []

    for server_name in sorted(unique_targets):
        name_tag, fqdn, port = parse_server_name(server_name)

        row_result = {
            "cert_id": args.cert_id,
            "cert_cn": cn,
            "server_name": server_name,
            "port": port,
            "expected_thumbprint": thumbprint,
            "status": "",
            "bound_thumbprint": "",
            "bound_subject": "",
            "instance_id": "",
            "region": "",
        }

        print(f"  {server_name:<50}", end=" ", flush=True)

        # Skip garbage entries like "*.owacloud.aspgov.com15020263"
        if fqdn.startswith("*") or not fqdn or "." not in fqdn:
            row_result["status"] = "SKIP_INVALID_NAME"
            print("SKIP (not a valid server FQDN)")
            results.append(row_result)
            continue

        session = pick_session_for_server(name_tag, matching_rows, profile_sessions)
        if session is None:
            row_result["status"] = "NO_PROFILE"
            print("SKIP (no authenticated AWS profile)")
            results.append(row_result)
            continue

        instance = find_instance_by_name(session, name_tag)
        if instance is None:
            row_result["status"] = "INSTANCE_NOT_FOUND"
            print("FAIL (EC2 instance not found)")
            results.append(row_result)
            continue

        row_result["instance_id"] = instance["instance_id"]
        row_result["region"] = instance["region"]

        bindings = get_iis_bindings(session, instance, debug=args.debug)

        status_val, bound_tp, bound_subject = determine_status(
            bindings, port, cn, thumbprint or None
        )
        row_result["status"] = status_val
        row_result["bound_thumbprint"] = bound_tp
        row_result["bound_subject"] = bound_subject

        print(status_val)
        results.append(row_result)

    # ── 5. Write report ───────────────────────────────────────────────────────
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = args.output or f"verify_iis_certs_{args.cert_id}_{timestamp}.csv"

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    print(f"\nWritten to : {out_path}")

    counts = Counter(r["status"] for r in results)
    print("\nSummary:")
    for s, c in sorted(counts.items()):
        marker = "  " if s in ("OK", "OK_SUBJECT_MATCH", "SKIP_INVALID_NAME") else "! "
        print(f"  {marker}{s:<40} {c}")

    ok_statuses = {"OK", "OK_SUBJECT_MATCH", "SKIP_INVALID_NAME"}
    has_issues = any(r["status"] not in ok_statuses for r in results)
    sys.exit(1 if has_issues else 0)


if __name__ == "__main__":
    main()
