#!/usr/bin/env bash
# Phase 8: JWT authentication — Istio validates tokens at the edge;
#           GET /whoami returns decoded claims to the caller.
#
# What this phase demonstrates:
#   1. RequestAuthentication  — istiod fetches the demo JWKS once and
#      distributes it to every Envoy sidecar.  A bad/expired token → 401
#      before the request reaches the app.
#   2. AuthorizationPolicy    — /whoami requires a valid JWT; other routes
#      are unaffected.
#   3. GET /whoami handler    — the app decodes the (already-verified) JWT
#      payload and echoes the claims as JSON.
#
# Token minting requires python3 (stdlib only) or the `jwt` CLI.
# The private key is the Istio project's public demo key:
#   https://raw.githubusercontent.com/istio/istio/master/security/tools/jwt/samples/key.pem
source "$(dirname "$0")/lib.sh"
require kubectl curl python3

log "Rebuild and reload the orders image (added GET /whoami)"
run docker build -f "$ROOT/build/Dockerfile" --build-arg SERVICE=orders -t orders:0.1.0 "$ROOT"
run kind load docker-image orders:0.1.0 --name "$CLUSTER_NAME"
run k -n "$NS" rollout restart deploy/orders
run k -n "$NS" rollout status deploy/orders --timeout=90s

log "Apply RequestAuthentication + AuthorizationPolicy for /whoami"
run k apply -f "$ROOT/k8s/jwt/request-authn.yaml"
run k apply -f "$ROOT/k8s/jwt/authz-require-jwt.yaml"
note "istiod distributes the JWKS to all sidecars; allow ~5 s for propagation."
sleep 6

log "Mint a demo JWT signed with the Istio demo private key"
# Download the demo private key from the Istio repo once.
DEMO_KEY_URL="https://raw.githubusercontent.com/istio/istio/master/security/tools/jwt/samples/key.pem"
KEY_FILE="$(mktemp --suffix=.pem)"
curl -sSfL "$DEMO_KEY_URL" -o "$KEY_FILE"
note "Downloaded demo key to $KEY_FILE"

# Mint a JWT: iss=testing@secure.istio.io, sub=alice, exp = now + 1h.
TOKEN="$(python3 "$ROOT/scripts/mint-jwt.py" "$KEY_FILE")"
note "TOKEN=$(echo "$TOKEN" | cut -c1-60)..."
rm -f "$KEY_FILE"

log "Verify routing: /orders still works WITHOUT a token (unaffected)"
gw_forward_start
expect "GET /orders/sku-1 (no token) → 200" 200 "$(code_gw /orders/sku-1 200)"

log "Verify /whoami → 403 without a token (authz policy blocks it)"
expect "GET /whoami (no token) → 403" 403 "$(code_gw /whoami 403)"

log "Verify /whoami → 401 with a FORGED (bad signature) token"
FORGED="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJoYWNrZXIiLCJpc3MiOiJ0ZXN0aW5nQHNlY3VyZS5pc3Rpby5pbyJ9.invalidsig"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FORGED" "http://localhost:${GW_PORT}/whoami")
expect "GET /whoami (forged token) → 401" 401 "$CODE"

log "Verify /whoami → 200 with a valid token, echoes JWT claims"
RESP=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${GW_PORT}/whoami")
echo "  response: $RESP"
# Check that the issuer claim round-trips correctly.
ISS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('iss','<missing>'))")
expect "iss claim == testing@secure.istio.io" "testing@secure.istio.io" "$ISS"
SUB=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sub','<missing>'))")
expect "sub claim == alice" "alice" "$SUB"

log "Inspect: show the Envoy filter chain that enforces JWT"
run istioctl proxy-config listener "deploy/demo-gateway-istio.$NS" --port 80 -o json \
  | python3 -c "
import sys, json
cfg = json.load(sys.stdin)
for l in cfg:
    for fc in l.get('filterChains', []):
        for f in fc.get('filters', []):
            if 'jwt_authn' in f.get('name', '') or 'jwt' in str(f).lower():
                print(json.dumps(f, indent=2)[:600])
                break
"

log "Phase 8 done. Summary:"
cat <<'EOF'
  RequestAuthentication  (k8s/jwt/request-authn.yaml)
    - Istio fetches the JWKS and distributes it to every proxy.
    - Bad/expired tokens → 401 at the sidecar, before the app sees the request.

  AuthorizationPolicy    (k8s/jwt/authz-require-jwt.yaml)
    - GET /whoami requires a valid principal (iss/sub from the token).
    - Requests without a valid token are denied by this DENY rule (notRequestPrincipals).

  GET /whoami            (cmd/orders/main.go)
    - Trusts Istio's prior validation; decodes the payload segment only.
    - Returns the raw JWT claims as JSON — useful for debugging identity.
EOF
