#!/usr/bin/env bash
# Phase 5: STRICT mTLS, default-deny, then explicit allow rules. Prints PASS/FAIL per check.
source "$(dirname "$0")/lib.sh"
require kubectl curl
gw_forward_start

INV_URL="http://inventory.$NS.svc.cluster.local/stock/sku-1"

log "Baseline (PERMISSIVE, no authz): everything works"
expect "gateway -> orders" 200 "$(code_gw /orders/sku-1)"
expect "legacy plaintext -> inventory" 200 "$(code_mesh legacy "$INV_URL")"

log "Enforce STRICT mTLS in namespace $NS"
run k apply -f "$ROOT/k8s/mesh/peer-auth-strict.yaml"; sleep 5
expect "legacy plaintext -> inventory is rejected" 000 "$(code_mesh legacy "$INV_URL")"
expect "meshed curl -> inventory (mTLS)" 200 "$(code_mesh "$NS" "$INV_URL")"
expect "gateway -> orders" 200 "$(code_gw /orders/sku-1)"

log "Default deny: empty AuthorizationPolicy"
run k apply -f "$ROOT/k8s/mesh/authz-deny-all.yaml"; sleep 5
expect "gateway -> orders now denied" 403 "$(code_gw /orders/sku-1)"
expect "meshed curl -> inventory denied" 403 "$(code_mesh "$NS" "$INV_URL")"

log "Allow only: gateway SA -> orders, orders SA -> inventory (GET)"
run k apply -f "$ROOT/k8s/mesh/authz-allow.yaml"; sleep 5
run k -n "$NS" get authorizationpolicy
expect "gateway -> orders -> inventory" 200 "$(code_gw /orders/sku-1)"
expect "meshed curl (SA curl) -> inventory denied" 403 "$(code_mesh "$NS" "$INV_URL")"
expect "meshed curl (SA curl) -> orders denied" 403 "$(code_mesh "$NS" http://orders/orders/sku-1)"

log "Why 403: look at the denying sidecar's access log"
try k -n "$NS" logs deploy/inventory-v1 -c istio-proxy --tail=5
note "Identity = SPIFFE ID spiffe://cluster.local/ns/<ns>/sa/<serviceaccount>, so each Deployment needs its own ServiceAccount."

log "Phase 5 done. Next: script/05-phase6-traffic-management.sh"
