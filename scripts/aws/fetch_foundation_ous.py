"""
Fetch AWS SSO accounts matching a pattern and display/export config entries.

Usage:  python fetch_foundation_ous.py
        python fetch_foundation_ous.py --pattern "PALegacy*"
        python fetch_foundation_ous.py --account PALegacyPlus
        python fetch_foundation_ous.py --pattern "PALegacyFinEnt*" --output config_snippet.txt
"""

import argparse
import json
import os
import sys

import boto3

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from aws_sso_helper import (
    resolve_account,
    ensure_sso_login,
    _get_sso_sessions,
)

# Default SSO session used when no --account is specified (backward compat)
_DEFAULT_SESSION = "foundation"
_DEFAULT_REGION = "us-east-1"


def list_all_accounts(token: str, region: str) -> list[dict]:
    """Fetch all accounts the user has access to via SSO."""
    sso = boto3.client("sso", region_name=region)
    accounts = []
    params: dict = {"accessToken": token, "maxResults": 100}
    while True:
        resp = sso.list_accounts(**params)
        accounts.extend(resp.get("accountList", []))
        if resp.get("nextToken"):
            params["nextToken"] = resp["nextToken"]
        else:
            break
    return accounts


def list_account_roles(token: str, account_id: str, region: str) -> list[str]:
    """Fetch roles the user has on a specific account."""
    sso = boto3.client("sso", region_name=region)
    resp = sso.list_account_roles(accessToken=token, accountId=account_id)
    return [r["roleName"] for r in resp.get("roleList", [])]


def main():
    parser = argparse.ArgumentParser(
        description="Fetch AWS SSO accounts and display config entries."
    )
    parser.add_argument("--pattern", default="PALegacyFinEnt*",
                        help="Account name prefix pattern (default: PALegacyFinEnt*)")
    parser.add_argument("--account", metavar="NAME",
                        help="Resolve a specific account by name or nickname and list it. "
                             "Overrides --pattern.")
    parser.add_argument("--output", default=None,
                        help="Write config snippet to file")
    args = parser.parse_args()

    if args.account:
        # Resolve to a specific account via accounts.json
        try:
            acct = resolve_account(args.account)
        except ValueError as e:
            print(f"Error: {e}")
            sys.exit(1)
        sso_session = acct["ssoSession"]
        sessions = _get_sso_sessions()
        region = sessions.get(sso_session, {}).get("region", _DEFAULT_REGION)
        print(f"Account: {acct['name']} ({acct['org']}, {acct['accountId']})")
        token = ensure_sso_login(sso_session)
        filter_ids = {acct["accountId"]}
    else:
        # Default behavior: Foundation session, prefix filter
        sso_session = _DEFAULT_SESSION
        region = _DEFAULT_REGION
        token = ensure_sso_login(sso_session)
        filter_ids = None

    print(f"\nFetching accounts from '{sso_session}' session...")
    all_accounts = list_all_accounts(token, region)
    print(f"Total accounts you have access to: {len(all_accounts)}")

    if filter_ids:
        matched = [a for a in all_accounts if a.get("accountId") in filter_ids]
    else:
        prefix = args.pattern.rstrip("*")
        matched = [a for a in all_accounts if a.get("accountName", "").startswith(prefix)]

    matched.sort(key=lambda a: a["accountName"])
    print(f"Matching accounts: {len(matched)}\n")

    if not matched:
        print("No matching accounts found.")
        return

    print(f"{'Account Name':<35} {'Account ID':<15} {'Roles'}")
    print("-" * 90)

    sso_session_label = acct["ssoSession"] if args.account else sso_session
    config_lines = []
    for a in matched:
        name = a["accountName"]
        acct_id = a["accountId"]
        roles = list_account_roles(token, acct_id, region)
        roles_str = ", ".join(roles)
        print(f"{name:<35} {acct_id:<15} {roles_str}")

        role = roles[0] if roles else "cst-comm-cloudadmin"
        config_lines.append(f"""[profile {name}]
sso_session    = {sso_session_label}
sso_account_id = {acct_id}
sso_role_name  = {role}
region         = {region}
""")

    snippet = "\n".join(config_lines)
    print(f"\n{'='*60}")
    print("Config snippet:")
    print(f"{'='*60}\n")
    print(snippet)

    if args.output:
        with open(args.output, "w") as f:
            f.write(snippet)
        print(f"\nAlso saved to: {args.output}")


if __name__ == "__main__":
    main()
