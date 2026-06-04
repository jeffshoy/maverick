"""
Generate aws-configs/cloudops.config and aws-configs/accounts.json by querying
both Foundation and Legacy SSO instances via list_accounts.

Usage:
    python aws-configs/tools/generate_aws_config.py
    python aws-configs/tools/generate_aws_config.py --dry-run

Outputs (relative to repo root, where this script should be run from):
    aws-configs/cloudops.config   — AWS CLI config file (both SSO sessions + all profiles)
    aws-configs/accounts.json     — Master account registry for name/fuzzy lookup

Run monthly or whenever a teammate hits a missing-account error, then submit a PR.
"""

import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# SSO session definitions — both orgs
# ---------------------------------------------------------------------------
SSO_SESSIONS = [
    {
        "name": "foundation",
        "startUrl": "https://d-9067f93f22.awsapps.com/start",
        "region": "us-east-1",
        "role": "cst-comm-cloudadmin",
        "profilePrefix": "",
    },
    {
        "name": "legacy",
        "startUrl": "https://centralsquare.awsapps.com/start",
        "region": "us-east-1",
        "role": "Cloud-Administrator",
        "profilePrefix": "legacy-",
    },
]

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_OUT = REPO_ROOT / "aws-configs" / "cloudops.config"
ACCOUNTS_OUT = REPO_ROOT / "aws-configs" / "accounts.json"
NICKNAMES_FILE = REPO_ROOT / "aws-configs" / "nicknames.json"


# ---------------------------------------------------------------------------
# SSO token helpers
# ---------------------------------------------------------------------------

def get_access_token(start_url: str) -> str | None:
    """Return the cached SSO access token for start_url, or None."""
    cache_dir = Path.home() / ".aws" / "sso" / "cache"
    files = sorted(cache_dir.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    for f in files:
        try:
            data = json.loads(f.read_text())
            if data.get("startUrl") == start_url and data.get("accessToken"):
                return data["accessToken"]
        except Exception:
            continue
    return None


def ensure_sso_login(session: dict) -> str:
    """Return a valid access token, triggering browser login if needed."""
    token = get_access_token(session["startUrl"])
    if token:
        print(f"  [{session['name']}] SSO session active.")
        return token
    print(f"  [{session['name']}] SSO session expired or missing. Opening browser...")
    subprocess.run(
        ["aws", "sso", "login", "--sso-session", session["name"]],
        check=True,
    )
    token = get_access_token(session["startUrl"])
    if not token:
        print(f"  [{session['name']}] ERROR: could not read access token after login.")
        sys.exit(1)
    return token


# ---------------------------------------------------------------------------
# Account enumeration
# ---------------------------------------------------------------------------

def list_all_accounts(token: str, region: str) -> list[dict]:
    """Paginate sso:list-accounts and return the full account list."""
    import boto3
    sso = boto3.client("sso", region_name=region)
    accounts = []
    params: dict = {"accessToken": token, "maxResults": 100}
    while True:
        resp = sso.list_accounts(**params)
        accounts.extend(resp.get("accountList", []))
        next_token = resp.get("nextToken")
        if not next_token:
            break
        params["nextToken"] = next_token
    return accounts


# ---------------------------------------------------------------------------
# Config/JSON generation
# ---------------------------------------------------------------------------

HEADER = """\
# =============================================================================
# cloudops.config — AWS SSO profiles for both Foundation and Legacy orgs
#
# DO NOT EDIT BY HAND.
# Regenerate with:  python aws-configs/tools/generate_aws_config.py
# Then sync to ~/.aws/config via: pwsh aws-configs/tools/Sync-AwsConfig.ps1
# =============================================================================
"""

SSO_SESSION_BLOCK = """\
[sso-session {name}]
sso_start_url       = {startUrl}
sso_region          = {region}
sso_registration_scopes = sso:account:access
"""

PROFILE_BLOCK = """\
[profile {profile}]
sso_session    = {ssoSession}
sso_account_id = {accountId}
sso_role_name  = {role}
region         = {region}
output         = json
"""


def _normalize_nickname(s: str) -> str:
    import re
    return re.sub(r'[\s\-_]', '', s.lower())


def load_nicknames() -> dict[str, list[str]]:
    """Load aws-configs/nicknames.json; returns {} if the file doesn't exist yet."""
    if not NICKNAMES_FILE.exists():
        return {}
    return json.loads(NICKNAMES_FILE.read_text(encoding="utf-8"))


def validate_nicknames(nicknames_map: dict[str, list[str]], all_accounts: list[dict]) -> None:
    """
    Validate nicknames.json against the live account list.
    Raises SystemExit on:
      - a key that doesn't match any account name
      - the same normalized nickname appearing under two different account names
    """
    known_names = {a["name"] for a in all_accounts}

    # Unknown account keys
    unknown = [k for k in nicknames_map if k not in known_names]
    if unknown:
        print(f"\nERROR: nicknames.json references unknown account name(s): {unknown}")
        print("Fix the key(s) to match the exact AWS account name, then re-run.")
        sys.exit(1)

    # Duplicate normalized nicknames across different accounts
    seen: dict[str, str] = {}  # normalized -> account name
    dupes: list[str] = []
    for acct_name, nicks in nicknames_map.items():
        for nick in nicks:
            norm = _normalize_nickname(nick)
            if norm in seen and seen[norm] != acct_name:
                dupes.append(f"  '{nick}' (normalized: '{norm}') on both '{seen[norm]}' and '{acct_name}'")
            else:
                seen[norm] = acct_name
    if dupes:
        print("\nERROR: Duplicate nicknames found in nicknames.json:")
        for d in dupes:
            print(d)
        print("Each normalized nickname must be unique across all accounts.")
        sys.exit(1)


def build_profile_name(session: dict, account_name: str) -> str:
    return f"{session['profilePrefix']}{account_name}"


def generate(dry_run: bool = False) -> None:
    print("Generating AWS config and accounts registry...")
    nicknames_map = load_nicknames()
    if nicknames_map:
        print(f"  Loaded nicknames for {len(nicknames_map)} account(s) from {NICKNAMES_FILE.name}")

    all_accounts: list[dict] = []   # for accounts.json
    config_parts: list[str] = [HEADER]

    for session in SSO_SESSIONS:
        print(f"\nSession: {session['name']}")
        token = ensure_sso_login(session)

        print(f"  Fetching accounts from {session['startUrl']} ...")
        accounts = list_all_accounts(token, session["region"])
        accounts.sort(key=lambda a: a["accountName"])
        print(f"  Found {len(accounts)} accounts.")

        # SSO session block
        config_parts.append(SSO_SESSION_BLOCK.format(**session))

        for acct in accounts:
            profile = build_profile_name(session, acct["accountName"])
            config_parts.append(
                PROFILE_BLOCK.format(
                    profile=profile,
                    ssoSession=session["name"],
                    accountId=acct["accountId"],
                    role=session["role"],
                    region=session["region"],
                )
            )
            all_accounts.append({
                "name": acct["accountName"],
                "accountId": acct["accountId"],
                "org": session["name"],
                "ssoSession": session["name"],
                "profile": profile,
                "nicknames": nicknames_map.get(acct["accountName"], []),
            })

    # Validate nicknames before writing — fail loud on unknown names or duplicates
    validate_nicknames(nicknames_map, all_accounts)

    # Sort accounts.json by (name, org) — foundation before legacy for same name
    all_accounts.sort(key=lambda a: (a["name"], 0 if a["org"] == "foundation" else 1))

    config_text = "\n".join(config_parts)

    accounts_json = {
        "generatedAt": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ssoSessions": {s["name"]: {"startUrl": s["startUrl"], "region": s["region"], "role": s["role"]} for s in SSO_SESSIONS},
        "accounts": all_accounts,
    }

    if dry_run:
        print("\n--- DRY RUN: cloudops.config (first 40 lines) ---")
        for line in config_text.splitlines()[:40]:
            print(line)
        print("\n--- DRY RUN: accounts.json (first 5 accounts) ---")
        preview = dict(accounts_json)
        preview["accounts"] = all_accounts[:5]
        print(json.dumps(preview, indent=2))
        nicknamed = [a for a in all_accounts if a["nicknames"]]
        if nicknamed:
            print(f"\n--- DRY RUN: accounts with nicknames ({len(nicknamed)}) ---")
            for a in nicknamed:
                print(f"  {a['name']}: {a['nicknames']}")
        print(f"\n[dry-run] Would write {len(config_text.splitlines())} lines to {CONFIG_OUT}")
        print(f"[dry-run] Would write {len(all_accounts)} accounts to {ACCOUNTS_OUT}")
        return

    CONFIG_OUT.write_text(config_text, encoding="utf-8")
    ACCOUNTS_OUT.write_text(json.dumps(accounts_json, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(f"\nWrote {CONFIG_OUT}")
    print(f"Wrote {ACCOUNTS_OUT} ({len(all_accounts)} accounts)")
    print("\nNext steps:")
    print("  1. Review the diff: git diff aws-configs/")
    print("  2. Commit and submit a PR.")
    print("  3. Teammates run: pwsh aws-configs/tools/Sync-AwsConfig.ps1")


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate cloudops.config and accounts.json from both SSO orgs.")
    parser.add_argument("--dry-run", action="store_true", help="Preview output without writing files.")
    args = parser.parse_args()
    generate(dry_run=args.dry_run)


if __name__ == "__main__":
    main()
