#!/usr/bin/env bash
# Generate a 256-bit HS256 signing key for JWT demo and write:
#   k8s/jwt/jwt-secret.key  — raw base64url-encoded secret (keep private)
#   k8s/jwt/jwks.json       — JWKS document consumed by Istio RequestAuthentication
#
# Re-running overwrites both files, invalidating any previously-minted tokens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$ROOT/k8s/jwt"

KEY_FILE="$OUT_DIR/jwt-secret.key"
JWKS_FILE="$OUT_DIR/jwks.json"

# Generate 32 cryptographically random bytes and encode as base64url (no padding).
SECRET=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')

printf '%s' "$SECRET" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

# Build JWKS: a single symmetric key entry for HS256.
# Istio requires kty=oct, alg=HS256, use=sig.
cat > "$JWKS_FILE" <<EOF
{
  "keys": [
    {
      "kty": "oct",
      "use": "sig",
      "alg": "HS256",
      "k":   "$SECRET"
    }
  ]
}
EOF

echo "Generated HS256 key:"
echo "  secret : $KEY_FILE"
echo "  JWKS   : $JWKS_FILE"
