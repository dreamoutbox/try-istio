#!/usr/bin/env python3
"""Mint a demo JWT signed with the Istio demo RSA private key.

Usage: python3 mint-jwt.py <path-to-key.pem>

Outputs a single line: the signed JWT token.

This uses only the Python standard library (no PyJWT / cryptography needed).
It constructs the JWT manually and signs with PKCS#1 v1.5 / SHA-256 via
the `ssl` module (which wraps OpenSSL).
"""
import base64
import hashlib
import json
import os
import ssl
import struct
import sys
import time


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def load_der_private_key(pem_path: str) -> bytes:
    """Read a PEM file and return the DER-encoded private key bytes."""
    with open(pem_path, "rb") as f:
        pem = f.read()
    # Strip PEM armor and decode.
    lines = pem.splitlines()
    b64_lines = [l for l in lines if not l.startswith(b"-----")]
    return base64.b64decode(b"".join(b64_lines))


def rsa_sign_pkcs1_sha256(der_key: bytes, message: bytes) -> bytes:
    """Sign message with RSA-SHA256 using the raw DER private key via OpenSSL."""
    import subprocess
    import tempfile

    # Write DER key to a temp file and call openssl dgst for signing.
    with tempfile.NamedTemporaryFile(suffix=".der", delete=False) as kf:
        kf.write(der_key)
        kf_path = kf.name
    with tempfile.NamedTemporaryFile(delete=False) as mf:
        mf.write(message)
        mf_path = mf.name
    try:
        result = subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-sign", kf_path,
                "-keyform", "DER", mf_path,
            ],
            capture_output=True,
            check=True,
        )
        return result.stdout
    finally:
        os.unlink(kf_path)
        os.unlink(mf_path)


def mint(key_pem_path: str, iss: str = "testing@secure.istio.io",
         sub: str = "alice", ttl: int = 3600) -> str:
    header = {"alg": "RS256", "typ": "JWT"}
    now = int(time.time())
    payload = {
        "iss": iss,
        "sub": sub,
        "iat": now,
        "exp": now + ttl,
        "groups": ["demo-users"],
        "email": "alice@example.com",
    }

    header_enc = b64url(json.dumps(header, separators=(",", ":")).encode())
    payload_enc = b64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{header_enc}.{payload_enc}".encode()

    der_key = load_der_private_key(key_pem_path)
    signature = rsa_sign_pkcs1_sha256(der_key, signing_input)

    return f"{header_enc}.{payload_enc}.{b64url(signature)}"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <key.pem>", file=sys.stderr)
        sys.exit(1)
    print(mint(sys.argv[1]))
