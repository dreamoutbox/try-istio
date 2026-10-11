#!/usr/bin/env bash
# Phase 4: north-south ingress with a Gateway API Gateway + HTTPRoute.
source "$(dirname "$0")/lib.sh"
require kubectl curl

log "Apply Gateway + HTTPRoute"
run k apply -f "$ROOT/k8s/mesh/gateway.yaml"
note "Istio watches the Gateway and auto-provisions Deployment+Service 'demo-gateway-istio'."
note "Programmed can stay False without an external LB address, so wait on the Deployment instead."
for _ in $(seq 1 60); do k -n "$NS" get deploy/demo-gateway-istio >/dev/null 2>&1 && break; sleep 1; done
run k -n "$NS" rollout status deploy/demo-gateway-istio --timeout=120s
run k -n "$NS" get gateway,httproute
run k -n "$NS" get deploy,svc,pods -l gateway.networking.k8s.io/gateway-name=demo-gateway

log "Reach it from the host (Service is LoadBalancer <pending> on kind, so port-forward)"
gw_forward_start
runsh "curl -s localhost:$GW_PORT/orders/sku-1"
runsh "curl -s -o /dev/null -w '%{http_code}\n' localhost:$GW_PORT/nope"

log "Inspect the gateway's Envoy"
run istioctl proxy-status
run istioctl proxy-config routes "deploy/demo-gateway-istio.$NS"
run k -n "$NS" logs deploy/demo-gateway-istio --tail=5

note "Keep a forward open yourself with: kubectl --context $KUBE_CONTEXT -n $NS port-forward svc/demo-gateway-istio $GW_PORT:80"
log "Phase 4 done. Next: scripts/04-phase5-authz-policies.sh"
