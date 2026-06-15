#!/usr/bin/env python3
"""Sectigo MCP stdio proxy.

Bridges Claude Code (JSON-RPC over stdio) to the hosted Sectigo MCP server at
https://mcp.enterprise.sectigo.com/mcp using OAuth 2.0 client credentials.

Required env vars:
  SECTIGO_CLIENT_ID      OAuth client ID from SCM admin console
  SECTIGO_CLIENT_SECRET  OAuth client secret from SCM admin console

The token is fetched on first use and refreshed automatically when it expires.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TOKEN_URL = "https://auth.sso.sectigo.com/auth/realms/apiclients/protocol/openid-connect/token"
MCP_URL = "https://mcp.enterprise.sectigo.com/mcp"

_token: str | None = None
_token_expiry: float = 0.0


def _fetch_token() -> str:
    client_id = os.environ.get("SECTIGO_CLIENT_ID")
    client_secret = os.environ.get("SECTIGO_CLIENT_SECRET")
    if not client_id or not client_secret:
        _die("Missing SECTIGO_CLIENT_ID or SECTIGO_CLIENT_SECRET env vars")

    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
    }).encode()

    req = urllib.request.Request(TOKEN_URL, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")

    try:
        with urllib.request.urlopen(req) as r:
            data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")
        _die(f"Token fetch failed HTTP {e.code}: {body_text[:300]}")
    except urllib.error.URLError as e:
        _die(f"Token fetch network error: {e.reason}")

    if "access_token" not in data:
        _die(f"No access_token in response: {data}")

    return data["access_token"], data.get("expires_in", 300)


def _get_token() -> str:
    global _token, _token_expiry
    # Refresh 30 seconds before expiry
    if _token is None or time.monotonic() >= _token_expiry - 30:
        token, expires_in = _fetch_token()
        _token = token
        _token_expiry = time.monotonic() + expires_in
    return _token


def _forward(payload: bytes) -> bytes:
    token = _get_token()
    req = urllib.request.Request(MCP_URL, data=payload, method="POST")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")

    try:
        with urllib.request.urlopen(req) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        # Surface as a JSON-RPC error so Claude Code sees it cleanly
        return json.dumps({
            "jsonrpc": "2.0",
            "id": None,
            "error": {"code": -32000, "message": f"HTTP {e.code} from MCP server: {body[:300]}"},
        }).encode()
    except urllib.error.URLError as e:
        return json.dumps({
            "jsonrpc": "2.0",
            "id": None,
            "error": {"code": -32000, "message": f"Network error: {e.reason}"},
        }).encode()


def _die(msg: str) -> None:
    sys.stderr.write(f"[sectigo-mcp-proxy] {msg}\n")
    sys.exit(1)


def main() -> None:
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    while True:
        # MCP stdio framing: each message is a line of JSON
        line = stdin.readline()
        if not line:
            break

        line = line.strip()
        if not line:
            continue

        response = _forward(line)
        stdout.write(response + b"\n")
        stdout.flush()


if __name__ == "__main__":
    main()
