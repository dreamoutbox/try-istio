#!/usr/bin/env python3
"""Mint a demo JWT signed with an HS256 secret key.

Usage: python3 mint-jwt.py <path-to-jwt-secret.key> [sub] [ttl_seconds]

  jwt-secret.key  File containing the raw base64url-encoded secret produced
                  by scripts/gen-jwt-key.sh.

Outputs a single line: the signed JWT token.

Uses only the Python standard library (hmac, hashlib) — no third-party packages.
"""
import base64
import hashlib
import hmac
import json
import sys
import time


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint(key_path: str, iss: str = "try-istio@local",
         sub: str = "alice", ttl: int = 3600) -> str:
    with open(key_path) as f:
        # Key file contains a base64url-encoded secret (no newline / padding).
        secret = base64.urlsafe_b64decode(f.read().strip() + "==")

    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {
        "iss": iss,
        "sub": sub,
        "iat": now,
        "exp": now + ttl,
        "groups": ["demo-users"],
        "email": f"{sub}@example.com",
    }

    header_enc = b64url(json.dumps(header, separators=(",", ":")).encode())
    payload_enc = b64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{header_enc}.{payload_enc}".encode()

    sig = hmac.new(secret, signing_input, hashlib.sha256).digest()
    return f"{header_enc}.{payload_enc}.{b64url(sig)}"


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <jwt-secret.key> [sub] [ttl_seconds]",
              file=sys.stderr)
        sys.exit(1)

    key_path = sys.argv[1]
    sub = sys.argv[2] if len(sys.argv) > 2 else "alice"
    ttl = int(sys.argv[3]) if len(sys.argv) > 3 else 3600

    print(mint(key_path, sub=sub, ttl=ttl))
