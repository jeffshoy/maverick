"""
CentOS CA Trust Store Updater
Diagnoses and repairs stale CA trust stores on CentOS EC2 instances via AWS SSM,
so TLS connections to services like S3 (signed by newer Amazon Trust Services
roots) stop failing with "unable to get local issuer certificate".

Modes:
  --check      (default) Read-only diagnostic: reports whether the Amazon
               root CAs are present and whether a live TLS handshake to the
               target S3 endpoint succeeds.
  --apply      Remediate: back up the trust store, try `yum update
               ca-certificates` (expected to fail on EOL CentOS 7 whose
               mirrors are dead), fall back to installing the Amazon Trust
               Services root CAs as anchors, then re-verify.
  --rollback   Restore a backup produced by --apply (requires a single
               --instance and the BACKUP_DIR it printed).

Usage:
  python update_ca_trust.py --account CLOUD-Concord-Engage-PROD --all-centos --check
  python update_ca_trust.py --account CLOUD-Concord-Engage-PROD --instance i-0f53db933daa78bd3 --apply --dry-run
  python update_ca_trust.py --account CLOUD-Concord-Engage-PROD --instance i-0f53db933daa78bd3 --apply
  python update_ca_trust.py --account CLOUD-Concord-Engage-PROD --instance i-0f53db933daa78bd3 --rollback /root/ca-trust-backup-20260806120000

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

TARGET_ENDPOINT = "s3.ca-central-1.amazonaws.com"
DEFAULT_REGION = "ca-central-1"

CERTS_DIR = Path(__file__).resolve().parent / "certs"
ANCHOR_MAP = [
    ("AmazonRootCA1.pem", "amazon-root-ca-1.pem"),
    ("AmazonRootCA2.pem", "amazon-root-ca-2.pem"),
    ("AmazonRootCA3.pem", "amazon-root-ca-3.pem"),
    ("AmazonRootCA4.pem", "amazon-root-ca-4.pem"),
    ("SFSRootCAG2.pem", "starfield-services-root-g2.pem"),
]
ROOT_SUBJECT_NAMES = [
    "Amazon Root CA 1",
    "Amazon Root CA 2",
    "Amazon Root CA 3",
    "Amazon Root CA 4",
    "Starfield Services Root Certificate Authority - G2",
]


# =============================================================================
# Bash payloads sent via SSM AWS-RunShellScript
# =============================================================================

CHECK_SCRIPT = r"""
#!/bin/bash
set -u
EP="__ENDPOINT__"
B="/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
L="/etc/pki/tls/certs/ca-bundle.crt"

echo "HOST|$(hostname -f 2>/dev/null || hostname)"
echo "OS|$(tr -d '\n' < /etc/redhat-release 2>/dev/null)"
echo "CACERTS_RPM|$(rpm -q ca-certificates 2>/dev/null | tr '\n' ' ')"
echo "OPENSSL_VER|$(openssl version 2>&1)"
echo "CLOCK_UTC|$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "BUNDLE_MTIME|$(stat -c %y "$B" 2>/dev/null)"
echo "BUNDLE_COUNT|$(grep -c 'BEGIN CERTIFICATE' "$B" 2>/dev/null || echo 0)"

if [ -L "$L" ]; then
  echo "LEGACY_LINK|symlink:$(readlink -f "$L")"
elif [ -f "$L" ]; then
  echo "LEGACY_LINK|REGULAR_FILE_OVERRIDE"
else
  echo "LEGACY_LINK|MISSING"
fi

TMPDIR=$(mktemp -d)
if [ -f "$B" ]; then
  awk -v dir="$TMPDIR" 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; f=dir "/cert" n ".pem"} {if (f!="") print > f} /END CERTIFICATE/{f=""}' "$B"
fi
SUBJECTS=""
for f in "$TMPDIR"/cert*.pem; do
  [ -f "$f" ] || continue
  SUBJECTS="$SUBJECTS
$(openssl x509 -noout -subject -in "$f" 2>/dev/null)"
done
rm -rf "$TMPDIR"

for name in "Amazon Root CA 1" "Amazon Root CA 2" "Amazon Root CA 3" "Amazon Root CA 4" "Starfield Services Root Certificate Authority - G2"; do
  key=$(echo "$name" | tr ' -' '__')
  if printf '%s' "$SUBJECTS" | grep -qF "$name"; then
    echo "ROOT_${key}|present"
  else
    echo "ROOT_${key}|missing"
  fi
done

HS=$(timeout 20 openssl s_client -connect "$EP:443" -servername "$EP" </dev/null 2>&1)
VR=$(printf '%s\n' "$HS" | sed -n 's/^ *Verify return code: *//p' | tail -1)
echo "OPENSSL_VERIFY|${VR:-NO_OUTPUT}"
ISSUER=$(printf '%s\n' "$HS" | awk '/Certificate chain/{f=1} f && / i:/{print; exit}' | sed 's/^ *//')
echo "PEER_ISSUER|${ISSUER:-NONE}"

timeout 20 curl -sS -o /dev/null -w 'CURL_HTTP|%{http_code}\n' "https://$EP/" 2>/tmp/.cacheck-err.$$
CURL_RC=$?
echo "CURL_RC|$CURL_RC"
echo "CURL_ERR|$(tr -d '\n' < /tmp/.cacheck-err.$$ 2>/dev/null)"
rm -f /tmp/.cacheck-err.$$

if [ "$CURL_RC" -eq 0 ]; then
  echo "RESULT|TLS_OK"
else
  echo "RESULT|TLS_FAIL"
fi
"""


APPLY_SCRIPT_TEMPLATE = r"""
#!/bin/bash
set -u
EP="__ENDPOINT__"
A="/etc/pki/ca-trust/source/anchors"
EXT="/etc/pki/ca-trust/extracted"
LEGACY="/etc/pki/tls/certs/ca-bundle.crt"

if [ "$(id -u)" -ne 0 ]; then
  echo "RESULT|NOT_ROOT"
  exit 1
fi

check_tls() {
  timeout 20 curl -sS -o /dev/null "https://$EP/" >/dev/null 2>&1
}

TS=$(date +%Y%m%d%H%M%S)
BK="/root/ca-trust-backup-$TS"
echo "BACKUP_DIR|$BK"
mkdir -p "$BK"
cp -a "$EXT" "$BK/extracted" 2>/dev/null
cp -a "$A" "$BK/anchors" 2>/dev/null
if [ -f "$LEGACY" ]; then cp -aL "$LEGACY" "$BK/ca-bundle.crt.legacy" 2>/dev/null; fi
rpm -q ca-certificates > "$BK/rpm-version.txt" 2>&1

if [ ! -d "$BK/extracted" ]; then
  echo "RESULT|BACKUP_FAILED"
  exit 1
fi
echo "BACKUP_OK|1"

if check_tls; then
  echo "CHANGED|0"
  echo "RESULT|ALREADY_TRUSTED"
  exit 0
fi

YUM_OUT=$(timeout 180 yum update -y ca-certificates 2>&1)
YUM_RC=$?
echo "YUM_RC|$YUM_RC"
echo "YUM_TAIL|$(printf '%s' "$YUM_OUT" | tail -3 | tr '\n' ';')"
if [ "$YUM_RC" -ne 0 ] || printf '%s' "$YUM_OUT" | grep -qiE 'Cannot find a valid baseurl|No more mirrors|Could not resolve host|Errno 14'; then
  echo "YUM_PATH|FAILED_FALLING_BACK"
else
  echo "YUM_PATH|SUCCEEDED"
fi

NEED_EXTRACT=0

install_anchor() {
  local name="$1"
  local dest="$A/$name"
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if ! openssl x509 -noout -in "$tmp" >/dev/null 2>&1; then
    echo "ANCHOR_${name}|INVALID_PEM"
    rm -f "$tmp"
    return
  fi
  echo "FPR|${name}|$(openssl x509 -noout -fingerprint -sha256 -in "$tmp" 2>/dev/null | cut -d= -f2)"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    echo "ANCHOR_${name}|unchanged"
    rm -f "$tmp"
    return
  fi
  install -m 0644 "$tmp" "$dest" && echo "ANCHOR_${name}|installed" || echo "ANCHOR_${name}|WRITE_FAILED"
  rm -f "$tmp"
  NEED_EXTRACT=1
}

__ANCHOR_BLOCK__

echo "CHANGED|$NEED_EXTRACT"

if [ -f "$LEGACY" ] && [ ! -L "$LEGACY" ]; then
  echo "LEGACY_RELINK|attempted"
  update-ca-trust force-enable > "$BK/force-enable.log" 2>&1
  sed 's/^/FORCE_ENABLE|/' "$BK/force-enable.log"
fi

update-ca-trust extract > "$BK/extract.log" 2>&1
EXTRACT_RC=$?
sed 's/^/EXTRACT|/' "$BK/extract.log"
echo "EXTRACT_RC|$EXTRACT_RC"
echo "BUNDLE_COUNT_POST|$(grep -c 'BEGIN CERTIFICATE' "$EXT/pem/tls-ca-bundle.pem" 2>/dev/null || echo 0)"

if check_tls; then
  echo "RESULT|REMEDIATED_OK"
else
  echo "RESULT|STILL_FAILING"
fi
"""


ROLLBACK_SCRIPT_TEMPLATE = r"""
#!/bin/bash
set -u
BK="__BACKUP_DIR__"
A="/etc/pki/ca-trust/source/anchors"
EXT="/etc/pki/ca-trust/extracted"

if [ "$(id -u)" -ne 0 ]; then
  echo "RESULT|NOT_ROOT"
  exit 1
fi

if [ ! -d "$BK/extracted" ] || [ ! -d "$BK/anchors" ]; then
  echo "RESULT|BAD_BACKUP"
  exit 1
fi

rm -f "$A"/amazon-root-ca-1.pem "$A"/amazon-root-ca-2.pem "$A"/amazon-root-ca-3.pem "$A"/amazon-root-ca-4.pem "$A"/starfield-services-root-g2.pem
cp -a "$BK/anchors/." "$A/" 2>/dev/null
rm -rf "$EXT"
cp -a "$BK/extracted" "$EXT"

update-ca-trust extract > /tmp/.ca-rollback-extract.$$ 2>&1
EXTRACT_RC=$?
sed 's/^/EXTRACT|/' /tmp/.ca-rollback-extract.$$
rm -f /tmp/.ca-rollback-extract.$$
echo "EXTRACT_RC|$EXTRACT_RC"
echo "BUNDLE_COUNT|$(grep -c 'BEGIN CERTIFICATE' "$EXT/pem/tls-ca-bundle.pem" 2>/dev/null || echo 0)"
echo "RESULT|ROLLED_BACK"
"""


def build_check_script() -> str:
    return CHECK_SCRIPT.replace("__ENDPOINT__", TARGET_ENDPOINT)


def build_apply_script() -> str:
    blocks = []
    for src, dest in ANCHOR_MAP:
        pem_path = CERTS_DIR / src
        pem_text = pem_path.read_text().strip() + "\n"
        blocks.append(f"install_anchor {dest} <<'PEMEOF'\n{pem_text}PEMEOF")
    anchor_block = "\n".join(blocks)
    script = APPLY_SCRIPT_TEMPLATE.replace("__ENDPOINT__", TARGET_ENDPOINT)
    return script.replace("__ANCHOR_BLOCK__", anchor_block)


def build_rollback_script(backup_dir: str) -> str:
    return ROLLBACK_SCRIPT_TEMPLATE.replace("__BACKUP_DIR__", backup_dir)


# =============================================================================
# AWS / SSM helpers
# =============================================================================

def get_client(profile, service, region):
    return boto3.Session(profile_name=profile, region_name=region).client(service)


def get_platform_info(profile, region, instance_id):
    ssm = get_client(profile, "ssm", region)
    resp = ssm.describe_instance_information(
        Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
    )
    info = resp.get("InstanceInformationList", [])
    return info[0] if info else None


def find_centos_instances(profile, region):
    ssm = get_client(profile, "ssm", region)
    ec2 = get_client(profile, "ec2", region)
    matches = []
    paginator = ssm.get_paginator("describe_instance_information")
    for page in paginator.paginate():
        for info in page["InstanceInformationList"]:
            if info.get("PlatformType") == "Linux" and "CentOS" in (info.get("PlatformName") or ""):
                matches.append(info)
    if not matches:
        return []
    ids = [m["InstanceId"] for m in matches]
    resp = ec2.describe_instances(InstanceIds=ids)
    names = {}
    for res in resp["Reservations"]:
        for inst in res["Instances"]:
            tag_name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "")
            names[inst["InstanceId"]] = tag_name or "N/A"
    return [
        {
            "InstanceId": m["InstanceId"],
            "Name": names.get(m["InstanceId"], "N/A"),
            "PlatformName": m.get("PlatformName"),
            "PlatformVersion": m.get("PlatformVersion"),
            "PingStatus": m.get("PingStatus"),
        }
        for m in matches
    ]


def run_ssm_command(profile, region, instance_id, script, timeout=300):
    ssm = get_client(profile, "ssm", region)
    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [script]},
            TimeoutSeconds=timeout,
        )
    except Exception as e:
        return "", str(e), "ERROR"
    cmd_id = resp["Command"]["CommandId"]
    poll_interval = 5
    max_polls = (timeout // poll_interval) + 30
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
    print(f"  OS:              {kv.get('OS', 'N/A')}")
    print(f"  ca-certificates: {kv.get('CACERTS_RPM', 'N/A')}")
    print(f"  Clock (UTC):     {kv.get('CLOCK_UTC', 'N/A')}")
    print(f"  Legacy link:     {kv.get('LEGACY_LINK', 'N/A')}")
    print(f"  Bundle count:    {kv.get('BUNDLE_COUNT', 'N/A')}")
    any_present = False
    for root_name in ROOT_SUBJECT_NAMES:
        key = "ROOT_" + root_name.replace(" ", "_").replace("-", "_")
        state = kv.get(key, "unknown")
        print(f"  {root_name}: {state}")
        if state == "present":
            any_present = True
    print(f"  OpenSSL verify:  {kv.get('OPENSSL_VERIFY', 'N/A')}")
    print(f"  Peer issuer:     {kv.get('PEER_ISSUER', 'N/A')}")
    print(f"  curl RC:         {kv.get('CURL_RC', 'N/A')}  ({kv.get('CURL_ERR', '')})")
    result = kv.get("RESULT", "UNKNOWN")
    print(f"  RESULT: {result}")
    if result == "TLS_FAIL" and any_present:
        print("  WARNING: a target root CA is already present in the trust store yet the "
              "handshake still fails. This is NOT the stale-trust-store scenario -- suspect "
              "TLS interception, clock skew, or a clobbered legacy ca-bundle.crt. "
              "Do not remediate until this is explained.")


def print_apply_result(name, instance_id, kv, status, stderr):
    print(f"\n--- {name} ({instance_id}) ---")
    if status != "Success":
        print(f"  SSM STATUS: {status}")
        if stderr:
            print(f"  STDERR: {stderr}")
        return
    if kv.get("RESULT") == "ALREADY_TRUSTED":
        print("  Already trusted -- no changes made (idempotent).")
        return
    print(f"  Backup dir:  {kv.get('BACKUP_DIR', 'N/A')}")
    print(f"  Yum path:    {kv.get('YUM_PATH', 'N/A')} (rc={kv.get('YUM_RC', 'N/A')})")
    for src, dest in ANCHOR_MAP:
        state = kv.get(f"ANCHOR_{dest}", "N/A")
        print(f"  Anchor {dest}: {state}")
    print(f"  Bundle count (post): {kv.get('BUNDLE_COUNT_POST', 'N/A')}")
    print(f"  RESULT: {kv.get('RESULT', 'UNKNOWN')}")


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="Diagnose/repair stale CA trust store on CentOS EC2 instances via SSM")
    parser.add_argument("--account", required=True, help="Account name or nickname (e.g. CLOUD-Concord-Engage-PROD)")
    parser.add_argument("--region", default=DEFAULT_REGION, help=f"AWS region (default: {DEFAULT_REGION})")
    parser.add_argument("--instance", action="append", metavar="INSTANCE_ID", help="Target instance ID (repeatable)")
    parser.add_argument("--all-centos", action="store_true", help="Target all CentOS/Linux instances found via SSM in this account/region")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Read-only diagnostic (default)")
    mode.add_argument("--apply", action="store_true", help="Remediate: yum update, fall back to installing Amazon root CAs")
    mode.add_argument("--rollback", metavar="BACKUP_DIR", help="Restore a prior --apply backup (requires exactly one --instance)")
    parser.add_argument("--dry-run", action="store_true", help="With --apply: run the check only, report intended action, make no changes")
    args = parser.parse_args()

    if args.rollback and (args.all_centos or not args.instance or len(args.instance) != 1):
        parser.error("--rollback requires exactly one --instance and cannot be combined with --all-centos")
    if not args.instance and not args.all_centos:
        parser.error("Provide --instance INSTANCE_ID (repeatable) or --all-centos")

    try:
        acct = resolve_account(args.account)
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)
    profile = acct["profile"]
    print(f"Account: {acct['name']} ({acct['org']}, {acct['accountId']})")
    ensure_profile_session(profile, acct["ssoSession"])

    if args.all_centos:
        print(f"\nDiscovering CentOS instances in {args.region}...")
        targets = find_centos_instances(profile, args.region)
        if not targets:
            print("No CentOS instances found via SSM in this region.")
            sys.exit(1)
        for t in targets:
            print(f"  {t['InstanceId']}  {t['Name']:<20} {t['PlatformName']} {t['PlatformVersion']} ({t['PingStatus']})")
    else:
        targets = []
        for iid in args.instance:
            info = get_platform_info(profile, args.region, iid)
            if not info:
                print(f"ERROR: {iid} not found via SSM in {args.region} (offline or wrong region).")
                sys.exit(1)
            if info.get("PlatformType") != "Linux" or "CentOS" not in (info.get("PlatformName") or ""):
                print(f"ERROR: {iid} is not CentOS/Linux per SSM (platform={info.get('PlatformName')} {info.get('PlatformType')}). Refusing to target it.")
                sys.exit(1)
            targets.append({"InstanceId": iid, "Name": iid})

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = os.path.join(os.environ.get("TEMP", r"C:\Temp"), f"ca-trust-update-{timestamp}.log")
    log_lines = []

    if args.rollback:
        iid = targets[0]["InstanceId"]
        print(f"\n=== ROLLBACK on {iid} using {args.rollback} ===")
        script = build_rollback_script(args.rollback)
        stdout, stderr, status = run_ssm_command(profile, args.region, iid, script, timeout=120)
        kv = parse_kv(stdout)
        log_lines.append(f"[{iid}] rollback status={status} result={kv.get('RESULT')}")
        print(stdout)
        if status != "Success":
            print(f"SSM STATUS: {status}  STDERR: {stderr}")

    elif args.apply:
        mode_label = "DRY-RUN" if args.dry_run else "APPLY"
        print(f"\n=== {mode_label}: {len(targets)} instance(s) ===")
        for t in targets:
            iid = t["InstanceId"]
            if args.dry_run:
                stdout, stderr, status = run_ssm_command(profile, args.region, iid, build_check_script(), timeout=60)
                kv = parse_kv(stdout)
                print_check_result(t["Name"], iid, kv, status, stderr)
                if status == "Success":
                    would = "would remediate (currently TLS_FAIL)" if kv.get("RESULT") == "TLS_FAIL" else "no action needed (already TLS_OK)"
                    print(f"  DRY-RUN: {would}")
                log_lines.append(f"[{iid}] dry-run result={kv.get('RESULT')}")
            else:
                stdout, stderr, status = run_ssm_command(profile, args.region, iid, build_apply_script(), timeout=240)
                kv = parse_kv(stdout)
                print_apply_result(t["Name"], iid, kv, status, stderr)
                log_lines.append(f"[{iid}] apply status={status} result={kv.get('RESULT')} backup={kv.get('BACKUP_DIR')}")

    else:
        print(f"\n=== CHECK: {len(targets)} instance(s) ===")
        for t in targets:
            iid = t["InstanceId"]
            stdout, stderr, status = run_ssm_command(profile, args.region, iid, build_check_script(), timeout=60)
            kv = parse_kv(stdout)
            print_check_result(t["Name"], iid, kv, status, stderr)
            log_lines.append(f"[{iid}] check status={status} result={kv.get('RESULT')}")

    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "w", encoding="utf-8") as fh:
            fh.write(f"ca-trust-update run {timestamp}\n")
            fh.write("\n".join(log_lines))
            fh.write("\n")
        print(f"\nLog written to: {log_path}")
    except Exception as e:
        print(f"WARNING: Could not write log file: {e}")


if __name__ == "__main__":
    main()
