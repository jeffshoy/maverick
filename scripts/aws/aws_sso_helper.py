"""
Shared AWS SSO helpers for CloudOps scripts.

Provides:
  - resolve_account(name)        Fuzzy name -> account dict from accounts.json
  - load_accounts()              All entries from accounts.json
  - get_sso_access_token(...)    Bearer-token cache reader (Pattern A scripts)
  - ensure_sso_login(...)        Ensure token valid, trigger browser login if not
  - ensure_profile_session(...)  STS-probe + sso login + return boto3.Session (Pattern B)
  - load_all_profiles()          All profiles from accounts.json as {name: account_id}
  - pick_profile_gui(profiles)   Tkinter account picker

Usage example (new scripts should follow this pattern):

    from aws_sso_helper import resolve_account, ensure_profile_session

    acct = resolve_account("PLUS")          # raises ValueError if ambiguous
    session = ensure_profile_session(acct["profile"], acct["ssoSession"])
    ec2 = session.client("ec2", region_name="us-east-1")
    # ... use ec2 normally
"""

import json
import os
import re
import subprocess
import sys
import tkinter as tk
from pathlib import Path

import boto3

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
_HERE = Path(__file__).resolve().parent
ACCOUNTS_JSON = _HERE.parent.parent / "aws-configs" / "accounts.json"

# SSO session metadata — read from accounts.json at import time
_SSO_SESSIONS: dict = {}

def _load_registry() -> dict:
    if not ACCOUNTS_JSON.exists():
        raise FileNotFoundError(
            f"accounts.json not found at {ACCOUNTS_JSON}. "
            "Run: python aws-configs/tools/generate_aws_config.py"
        )
    return json.loads(ACCOUNTS_JSON.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Account resolution
# ---------------------------------------------------------------------------

def load_accounts() -> list[dict]:
    """Return all account entries from accounts.json."""
    return _load_registry()["accounts"]


def get_sso_sessions() -> dict:
    """Return the ssoSessions block from accounts.json (cached)."""
    global _SSO_SESSIONS
    if not _SSO_SESSIONS:
        _SSO_SESSIONS = _load_registry().get("ssoSessions", {})
    return _SSO_SESSIONS


def _tokenize(s: str) -> list[str]:
    """Split a string on hyphens, underscores, and camelCase boundaries."""
    parts = re.split(r'(?<=[a-z])(?=[A-Z])|[-_]', s)
    return [p for p in parts if p]


def _token_score(query: str, candidate: str) -> int:
    qt = set(t.lower() for t in _tokenize(query))
    ct = set(t.lower() for t in _tokenize(candidate))
    return len(qt & ct)


def resolve_account(name: str) -> dict:
    """
    Fuzzy-match *name* against accounts.json and return one account dict:
    {name, accountId, org, ssoSession, profile}

    Match tiers (stops at first tier with >= 1 hit):
      1. Exact (case-sensitive)
      2. Case-insensitive exact
      3. Case-insensitive substring
      4. Token overlap

    Tie-breaking:
      - Same display name in both orgs: Foundation wins silently.
      - Multiple genuinely different accounts at the same tier: raises ValueError
        listing the candidates so the caller can prompt the user.

    Raises ValueError on no match (includes closest-5 suggestions) or on
    genuine ambiguity.
    """
    accounts = load_accounts()

    candidates = []

    # Tier 1: exact
    candidates = [a for a in accounts if a["name"] == name]

    # Tier 2: case-insensitive exact
    if not candidates:
        candidates = [a for a in accounts if a["name"].lower() == name.lower()]

    # Tier 3: substring
    if not candidates:
        candidates = [a for a in accounts if name.lower() in a["name"].lower()]

    # Tier 4: token overlap
    if not candidates:
        scored = sorted(
            [(a, _token_score(name, a["name"])) for a in accounts],
            key=lambda x: -x[1]
        )
        if scored and scored[0][1] > 0:
            top = scored[0][1]
            candidates = [a for a, s in scored if s == top]

    # No match
    if not candidates:
        by_overlap = sorted(accounts, key=lambda a: -sum(
            1 for c in name.lower() if c in a["name"].lower()
        ))
        suggestions = ", ".join(a["name"] for a in by_overlap[:5])
        raise ValueError(f"No account found matching '{name}'. Did you mean: {suggestions}?")

    # Single match — return directly
    if len(candidates) == 1:
        return candidates[0]

    # Same display name, Foundation vs Legacy — prefer Foundation silently
    names = {a["name"] for a in candidates}
    if len(names) == 1:
        foundation = [a for a in candidates if a["org"] == "foundation"]
        if len(foundation) == 1:
            return foundation[0]

    # Genuine ambiguity — caller must disambiguate
    listing = "; ".join(f"{a['name']} ({a['org']}, {a['accountId']})" for a in candidates)
    raise ValueError(
        f"Multiple accounts match '{name}': {listing}. "
        "Provide a more specific name."
    )


# ---------------------------------------------------------------------------
# Pattern A: bearer-token SSO (fetch_foundation_ous.py style)
# ---------------------------------------------------------------------------

def get_sso_access_token(start_url: str, region: str) -> str | None:
    """Return a cached SSO bearer token for start_url, or None."""
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


def ensure_sso_login(sso_session: str, start_url: str | None = None) -> str:
    """
    Return a valid SSO bearer token for the given session, triggering a
    browser login if the cached token is missing or expired.

    start_url is resolved from accounts.json when omitted.
    """
    sessions = get_sso_sessions()
    if start_url is None:
        if sso_session not in sessions:
            raise ValueError(f"Unknown SSO session '{sso_session}'. Check accounts.json.")
        start_url = sessions[sso_session]["startUrl"]
    region = sessions.get(sso_session, {}).get("region", "us-east-1")

    token = get_sso_access_token(start_url, region)
    if token:
        print(f"SSO session '{sso_session}' active.")
        return token

    print(f"SSO session '{sso_session}' expired or missing. Opening browser...")
    subprocess.run(["aws", "sso", "login", "--sso-session", sso_session], check=True)
    token = get_sso_access_token(start_url, region)
    if not token:
        print(f"Failed to get access token for session '{sso_session}' after login.")
        sys.exit(1)
    return token


# ---------------------------------------------------------------------------
# Pattern B: profile + STS probe (all GUI scripts)
# ---------------------------------------------------------------------------

def ensure_profile_session(profile: str, sso_session: str) -> boto3.Session:
    """
    Verify the profile's SSO token via sts.get_caller_identity. If expired,
    run `aws sso login --sso-session <sso_session>` using the CORRECT session
    (not hardcoded 'foundation'). Returns a live boto3.Session.
    """
    print(f"Checking SSO session for {profile}...", end=" ", flush=True)
    try:
        session = boto3.Session(profile_name=profile)
        identity = session.client("sts").get_caller_identity()
        print(f"OK - {identity['Arn']}")
        return session
    except Exception:
        print("expired.")
        print(f"Opening browser for SSO login ({sso_session})...")
        ret = subprocess.run(["aws", "sso", "login", "--sso-session", sso_session])
        if ret.returncode != 0:
            print("SSO login failed.")
            sys.exit(1)
        print("SSO login successful.")
        return boto3.Session(profile_name=profile)


# ---------------------------------------------------------------------------
# Profile loader (replaces load_foundation_profiles in each script)
# ---------------------------------------------------------------------------

def load_all_profiles() -> dict[str, str]:
    """
    Return {profile_name: account_id} for ALL profiles in accounts.json
    (both Foundation and Legacy). Replaces the old load_foundation_profiles()
    which only read ~/.aws/config and filtered to sso_session == 'foundation'.
    """
    return {a["profile"]: a["accountId"] for a in load_accounts()}


def get_sso_session_for_profile(profile: str) -> str:
    """Return the ssoSession name for a given profile name from accounts.json."""
    for a in load_accounts():
        if a["profile"] == profile:
            return a["ssoSession"]
    # Fallback: check if it looks like a legacy- prefixed profile
    return "legacy" if profile.startswith("legacy-") else "foundation"


# ---------------------------------------------------------------------------
# Tkinter GUI picker (shared by all Pattern-B scripts)
# ---------------------------------------------------------------------------

def pick_profile_gui(profiles: dict[str, str] | None = None, title: str = "Select AWS Account") -> str | None:
    """
    Show a searchable Tkinter listbox of AWS profiles and return the selected
    profile name, or None if the user cancelled.

    profiles: {profile_name: account_id}. Defaults to all entries in accounts.json.
    """
    if profiles is None:
        profiles = load_all_profiles()

    selected = {"profile": None}
    root = tk.Tk()
    root.title(title)
    root.geometry("500x400")
    root.resizable(False, False)

    tk.Label(root, text="Search and select AWS account:", font=("Segoe UI", 11)).pack(pady=(15, 5))
    search_var = tk.StringVar()
    tk.Entry(root, textvariable=search_var, font=("Segoe UI", 10), width=50).pack(pady=5)

    frame = tk.Frame(root)
    frame.pack(fill=tk.BOTH, expand=True, padx=20, pady=5)
    scrollbar = tk.Scrollbar(frame)
    scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
    listbox = tk.Listbox(frame, font=("Consolas", 10), yscrollcommand=scrollbar.set, width=60)
    listbox.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
    scrollbar.config(command=listbox.yview)

    profile_list = sorted(profiles.keys())

    def update_list(*_):
        q = search_var.get().lower()
        listbox.delete(0, tk.END)
        for p in profile_list:
            if q in p.lower():
                listbox.insert(tk.END, f"{p}  ({profiles[p]})")

    search_var.trace_add("write", update_list)
    update_list()

    def on_select(event=None):
        sel = listbox.curselection()
        if sel:
            selected["profile"] = listbox.get(sel[0]).split("  (")[0]
            root.destroy()

    listbox.bind("<Double-Button-1>", lambda e: on_select())
    root.bind("<Return>", lambda e: on_select() if listbox.curselection() else None)
    tk.Button(root, text="Select", command=on_select, font=("Segoe UI", 10), width=15).pack(pady=10)
    root.mainloop()
    return selected["profile"]


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print(f"accounts.json: {ACCOUNTS_JSON}")
    acct = resolve_account("PALegacyPlus")
    print(f"resolve_account('PALegacyPlus') -> {acct}")
    sessions = get_sso_sessions()
    print(f"SSO sessions: {list(sessions.keys())}")
    total = len(load_accounts())
    print(f"Total accounts: {total}")
