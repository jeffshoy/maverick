#!/usr/bin/env python3
"""Revoke Sectigo SCM SSL certificates by ID.

Reads a JSON array of certificate IDs (from a file or stdin) and revokes each
one via POST /api/ssl/v2/revoke/{id} using legacy header-based authentication
(login / password / customerUri).

Usage:
    export SECTIGO_LOGIN='your_user'
    export SECTIGO_PASSWORD='your_pass'
    export SECTIGO_CUSTOMER_URI='your_customer_uri'
    # optional, defaults to https://cert-manager.com
    export SECTIGO_BASE_URL='https://cert-manager.com'

    python revoke_certs.py ids.json
    python revoke_certs.py ids.json --reason "Key rotation" --reason-code 1
    echo '[123, 456]' | python revoke_certs.py -

Reason codes (Mozilla Root Store Policy):
    0 = unspecified
    1 = keyCompromise
    3 = affiliationChanged
    4 = superseded
    5 = cessationOfOperation
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Iterable

import urllib.error
import urllib.request


VALID_REASON_CODES = {0, 1, 3, 4, 5}


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


def load_ids(source: str) -> list[int]:
    raw = sys.stdin.read() if source == "-" else open(source, "r").read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        sys.exit(f"Input is not valid JSON: {e}")

    if not isinstance(data, list) or not all(isinstance(x, int) for x in data):
        sys.exit("Input must be a JSON array of integer certificate IDs.")

    if not data:
        sys.exit("No certificate IDs to revoke.")

    return data


def revoke_one(
    cert_id: int, reason: str, reason_code: int, creds: Credentials
) -> tuple[bool, str]:
    url = f"{creds.base_url}/api/ssl/v2/revoke/{cert_id}"
    payload = json.dumps({"reasonCode": reason_code, "reason": reason}).encode("utf-8")

    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("login", creds.login)
    req.add_header("password", creds.password)
    req.add_header("customerUri", creds.customer_uri)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")

    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status == 204:
                return True, "revoked"
            body = resp.read().decode("utf-8", errors="replace")
            return True, f"HTTP {resp.status}: {body[:200]}"
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        return False, f"HTTP {e.code}: {body[:200]}"
    except urllib.error.URLError as e:
        return False, f"network error: {e.reason}"


def revoke_all(
    ids: Iterable[int], reason: str, reason_code: int, creds: Credentials
) -> int:
    failures = 0
    for cert_id in ids:
        ok, message = revoke_one(cert_id, reason, reason_code, creds)
        status = "OK " if ok else "FAIL"
        print(f"[{status}] {cert_id}: {message}")
        if not ok:
            failures += 1
    return failures


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument(
        "ids_file",
        help="Path to a JSON file containing a list of certificate IDs, or '-' for stdin.",
    )
    p.add_argument(
        "--reason",
        default="Revoked via API script",
        help="Free-text revocation reason (1-512 chars). Default: %(default)r.",
    )
    p.add_argument(
        "--reason-code",
        type=int,
        default=0,
        choices=sorted(VALID_REASON_CODES),
        help="Mozilla Root Store reason code. Default: 0 (unspecified).",
    )
    args = p.parse_args()
    if not (1 <= len(args.reason) <= 512):
        p.error("--reason must be 1-512 characters")
    return args


def main() -> None:
    args = parse_args()
    creds = Credentials.from_env()
    ids = load_ids(args.ids_file)

    print(f"Revoking {len(ids)} certificate(s) against {creds.base_url}...")
    failures = revoke_all(ids, args.reason, args.reason_code, creds)

    print(f"\nDone. {len(ids) - failures} succeeded, {failures} failed.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
