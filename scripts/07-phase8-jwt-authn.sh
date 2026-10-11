#!/usr/bin/env bash
# Phase 8: JWT authentication — Istio validates HS256 tokens at the edge;
#           GET /whoami returns decoded claims to the caller.
#
# What this phase demonstrates:
#   1. gen-jwt-key.sh       — generates a 256-bit HS256 secret and writes
#      k8s/jwt/jwt-secret.key and k8s/jwt/jwks.json.
#   2. RequestAuthentication — istiod gets the inline JWKS and distributes it
#      to every Envoy sidecar.  A bad/expired token → 401 at the proxy.
#   3. AuthorizationPolicy  — /whoami requires a valid JWT; other routes are
#      unaffected.
#   4. GET /whoami handler  — the app decodes the (already-verified) JWT
#      payload and echoes the claims as JSON.
#
# Token minting uses python3 (stdlib only — hmac + hashlib, no PyJWT needed).
source "$(dirname "$0")/lib.sh"
require kubectl curl python3 openssl jq

log "Rebuild and reload the orders image (added GET /whoami)"
run docker build -f "$ROOT/build/Dockerfile" --build-arg SERVICE=orders -t orders:0.1.0 "$ROOT"
run kind load docker-image orders:0.1.0 --name "$CLUSTER_NAME"
run k -n "$NS" rollout restart deploy/orders
run k -n "$NS" rollout status deploy/orders --timeout=90s

log "Generate HS256 signing key"
run bash "$ROOT/scripts/gen-jwt-key.sh"

KEY_FILE="$ROOT/k8s/jwt/jwt-secret.key"
JWKS_FILE="$ROOT/k8s/jwt/jwks.json"

log "Patch RequestAuthentication with the generated JWKS"
PATCHED_AUTHN="$ROOT/k8s/jwt/request-authn-patched.yaml"
run python3 "$ROOT/scripts/patch-request-authn.py" \
  "$ROOT/k8s/jwt/request-authn.yaml" \
  "$JWKS_FILE" \
  "$PATCHED_AUTHN"
run k apply -f "$PATCHED_AUTHN"

log "Apply AuthorizationPolicy for /whoami"
run k apply -f "$ROOT/k8s/jwt/authz-require-jwt.yaml"
note "istiod distributes the JWKS to all sidecars; allow ~5 s for propagation."
sleep 6

log "Mint a demo JWT signed with our HS256 key"
TOKEN="$(python3 "$ROOT/scripts/mint-jwt.py" "$KEY_FILE")"
note "TOKEN=$(echo "$TOKEN" | cut -c1-60)..."

log "Verify routing: /orders still works WITHOUT a token (unaffected)"
gw_forward_start
expect "GET /orders/sku-1 (no token) → 200" 200 "$(code_gw /orders/sku-1 200)"

log "Verify /whoami → 403 without a token (authz policy blocks it)"
expect "GET /whoami (no token) → 403" 403 "$(code_gw /whoami 403)"

log "Verify /whoami → 401 with a FORGED (bad signature) token"
# Build a valid-looking HS256 token but signed with a different key.
FORGED_HEADER="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
FORGED_PAYLOAD="eyJzdWIiOiJoYWNrZXIiLCJpc3MiOiJ0cnktaXN0aW9AbG9jYWwifQ"
FORGED="$FORGED_HEADER.$FORGED_PAYLOAD.invalidsig"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FORGED" "http://localhost:${GW_PORT}/whoami")
expect "GET /whoami (forged token) → 401" 401 "$CODE"

log "Verify /whoami → 200 with a valid token, echoes JWT claims"
RESP=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${GW_PORT}/whoami")
echo "  response: $RESP"
ISS=$(echo "$RESP" | jq -r '.iss // "<missing>"')
expect "iss claim == try-istio@local" "try-istio@local" "$ISS"
SUB=$(echo "$RESP" | jq -r '.sub // "<missing>"')
expect "sub claim == alice" "alice" "$SUB"

log "Inspect: show the Envoy filter chain that enforces JWT"
run istioctl proxy-config listener "deploy/demo-gateway-istio.$NS" --port 80 -o json \
  | python3 "$ROOT/scripts/show-jwt-filter.py"

log "Phase 8 done. Summary:"
cat <<'EOF'
  gen-jwt-key.sh         (scripts/gen-jwt-key.sh)
    - Generates a 256-bit HS256 secret (k8s/jwt/jwt-secret.key).
    - Writes the matching JWKS document (k8s/jwt/jwks.json).

  RequestAuthentication  (k8s/jwt/request-authn.yaml)
    - Inline JWKS (HS256) distributed by istiod to every proxy.
    - Bad/expired tokens → 401 at the sidecar, before the app sees the request.

  AuthorizationPolicy    (k8s/jwt/authz-require-jwt.yaml)
    - GET /whoami requires a valid principal (iss/sub from the token).
    - Requests without a valid token are denied by this DENY rule (notRequestPrincipals).

  GET /whoami            (cmd/orders/main.go)
    - Trusts Istio's prior validation; decodes the payload segment only.
    - Returns the raw JWT claims as JSON — useful for debugging identity.
EOF
