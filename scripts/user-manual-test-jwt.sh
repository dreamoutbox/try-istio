#!/usr/bin/env bash
# Helper script to manually mint and test JWT authentication against the orders service.
#
# Usage:
#   scripts/user-manual-test-jwt.sh [subject]
#
# Steps:
#   1. Mints a valid HS256 JWT using the local key.
#   2. Ensures the gateway port-forward to the orders service is running.
#   3. Prints ready-to-use curl commands for valid, forged, and unauthenticated requests.
source "$(dirname "$0")/lib.sh"
require kubectl curl python3

SUB="${1:-alice}"
KEY_FILE="$ROOT/k8s/jwt/jwt-secret.key"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "Key file $KEY_FILE not found. Generating new key..."
  bash "$ROOT/scripts/gen-jwt-key.sh"
fi

TOKEN="$(python3 "$ROOT/scripts/mint-jwt.py" "$KEY_FILE" "$SUB")"

echo "================================================================================"
echo "Minted JWT for subject: $SUB"
echo "================================================================================"
echo "$TOKEN"
echo ""

PF_STARTED=0
# Check if gateway port-forward is already responding.
if ! curl -s -o /dev/null "http://localhost:${GW_PORT}/orders/sku-1"; then
  echo "Starting port-forward for demo-gateway (port ${GW_PORT})..."
  k -n "$NS" port-forward svc/demo-gateway-istio "${GW_PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  PF_STARTED=1
  trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

  # Wait for port-forward to be ready
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://localhost:${GW_PORT}/"; then
      break
    fi
    sleep 0.5
  done
else
  echo "Gateway port-forward is already active on localhost:${GW_PORT}"
fi

echo "================================================================================"
echo "Manual Test Commands"
echo "================================================================================"
echo ""
echo "1. Valid Token -> 200 OK (echoes claims):"
echo "curl -i -H \"Authorization: Bearer $TOKEN\" http://localhost:${GW_PORT}/whoami"
echo ""
echo "2. No Token -> 403 Forbidden (blocked by AuthorizationPolicy):"
echo "curl -i http://localhost:${GW_PORT}/whoami"
echo ""
echo "3. Forged / Invalid Token -> 401 Unauthorized (rejected by Envoy RequestAuthentication):"
echo "curl -i -H \"Authorization: Bearer invalid.token.signature\" http://localhost:${GW_PORT}/whoami"
echo ""
echo "4. Unprotected route -> 200 OK without token:"
echo "curl -i http://localhost:${GW_PORT}/orders/sku-1"
echo ""

echo "Sample run of test #1:"
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:${GW_PORT}/whoami"
echo ""
echo ""

if [[ "$PF_STARTED" -eq 1 ]]; then
  echo "Port-forward running on :${GW_PORT}. Press [Enter] to terminate."
  read -r _
fi
