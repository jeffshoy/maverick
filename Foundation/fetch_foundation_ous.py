"""
Fetch all AWS SSO accounts matching a pattern and generate ~/.aws/config entries.

Usage:  python fetch_foundation_ous.py
        python fetch_foundation_ous.py --pattern "PALegacy*"
        python fetch_foundation_ous.py --pattern "PALegacyFinEnt*" --output config_snippet.txt
"""

import argparse
import glob
import json
import os
import subprocess
import sys

import boto3

SSO_SESSION = "foundation"
SSO_REGION = "us-east-1"
SSO_START_URL = "https://d-9067f93f22.awsapps.com/start"


def get_access_token():
    """Read the cached SSO access token."""
    cache_dir = os.path.join(os.path.expanduser("~"), ".aws", "sso", "cache")
    files = glob.glob(os.path.join(cache_dir, "*.json"))
    for f in sorted(files, key=os.path.getmtime, reverse=True):
        try:
            with open(f) as fh:
                data = json.load(fh)
            if data.get("startUrl") == SSO_START_URL and data.get("accessToken"):
                return data["accessToken"]
        except Exception:
            continue
    return None


def ensure_sso_login():
    """Login if no valid token found."""
    token = get_access_token()
    if token:
        print("SSO session active.")
        return token
    print("SSO session expired. Opening browser...")
    subprocess.run(["aws", "sso", "login", "--sso-session", SSO_SESSION], check=True)
    token = get_access_token()
    if not token:
        print("Failed to get access token after login.")
        sys.exit(1)
    return token


def list_all_accounts(token):
    """Fetch all accounts the user has access to via SSO."""
    sso = boto3.client("sso", region_name=SSO_REGION)
    accounts = []
    params = {"accessToken": token, "maxResults": 100}
    while True:
        resp = sso.list_accounts(**params)
        accounts.extend(resp.get("accountList", []))
        if resp.get("nextToken"):
            params["nextToken"] = resp["nextToken"]
        else:
            break
    return accounts


def list_account_roles(token, account_id):
    """Fetch roles the user has on a specific account."""
    sso = boto3.client("sso", region_name=SSO_REGION)
    resp = sso.list_account_roles(accessToken=token, accountId=account_id)
    return [r["roleName"] for r in resp.get("roleList", [])]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pattern", default="PALegacyFinEnt*", help="Account name pattern (default: PALegacyFinEnt*)")
    parser.add_argument("--output", default=None, help="Write config snippet to file")
    args = parser.parse_args()

    # Convert glob pattern to simple prefix match
    prefix = args.pattern.rstrip("*")

    token = ensure_sso_login()

    print(f"\nFetching all accounts...")
    accounts = list_all_accounts(token)
    print(f"Total accounts you have access to: {len(accounts)}")

    # Filter
    matched = [a for a in accounts if a.get("accountName", "").startswith(prefix)]
    matched.sort(key=lambda a: a["accountName"])
    print(f"Accounts matching '{args.pattern}': {len(matched)}\n")

    if not matched:
        print("No matching accounts found.")
        return

    # Display table
    print(f"{'Account Name':<35} {'Account ID':<15} {'Roles'}")
    print("-" * 90)

    config_lines = []
    for acct in matched:
        name = acct["accountName"]
        acct_id = acct["accountId"]
        roles = list_account_roles(token, acct_id)
        roles_str = ", ".join(roles)
        print(f"{name:<35} {acct_id:<15} {roles_str}")

        # Generate config block using first role
        role = roles[0] if roles else "cst-comm-cloudadmin"
        config_lines.append(f"""[profile {name}]
sso_session    = foundation
sso_account_id = {acct_id}
sso_role_name  = {role}
region         = us-east-1
""")

    # Output config snippet
    snippet = "\n".join(config_lines)

    print(f"\n{'='*60}")
    print("Config snippet (copy-paste into ~/.aws/config):")
    print(f"{'='*60}\n")
    print(snippet)

    if args.output:
        with open(args.output, "w") as f:
            f.write(snippet)
        print(f"\nAlso saved to: {args.output}")


if __name__ == "__main__":
    main()
