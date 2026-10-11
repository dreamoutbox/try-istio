#!/usr/bin/env bash
# Phase 3: turn on sidecar injection and prove traffic is mTLS.
source "$(dirname "$0")/lib.sh"
require kubectl

log "Label namespace for injection and restart workloads"
run k label ns "$NS" istio-injection=enabled --overwrite
note "The webhook only mutates pods at CREATE time, so existing pods must be recreated."
run k -n "$NS" rollout restart deploy
for d in $(k -n "$NS" get deploy -o name); do run k -n "$NS" rollout status "$d" --timeout=120s; done
run k -n "$NS" get pods -o custom-columns='NAME:.metadata.name,INIT:.spec.initContainers[*].name,CONTAINERS:.spec.containers[*].name'

log "Create curl clients: meshed (ns $NS, own ServiceAccount) and non-meshed (ns legacy)"
run k create ns legacy --dry-run=client -o yaml | k apply -f -
for ns in "$NS" legacy; do
  k -n "$ns" create sa curl --dry-run=client -o yaml | k apply -f -
  k -n "$ns" create deployment curl --image="$CURL_IMAGE" --dry-run=client -o yaml -- sleep infinity | k apply -f -
  k -n "$ns" set serviceaccount deploy/curl curl
  k -n "$ns" rollout status deploy/curl --timeout=120s
done
run k -n legacy get pods
note "legacy has no sidecar (1/1 containers). $NS pods have 2/2."

log "Call chain from the meshed client"
run mesh_curl "$NS" http://orders/orders/sku-1

log "Proof 1: inventory sees the caller's SPIFFE identity (X-Forwarded-Client-Cert), only set on mTLS"
runsh "mesh_curl $NS http://orders/orders/sku-1 | grep -o 'URI=spiffe://[^;\"\\\\]*'"

log "Proof 2: istioctl's view of the pod and its workload certs"
ORDERS_POD="$(pod_of "$NS" orders)"
try istioctl x describe pod "$ORDERS_POD" -n "$NS"
run istioctl proxy-config secret "$ORDERS_POD.$NS"

log "Plain-text caller from the non-meshed namespace is still accepted (default mode is PERMISSIVE)"
run mesh_curl legacy http://inventory.$NS.svc.cluster.local/stock/sku-1
note "xfcc is empty in that response: no client cert. Phase 5 flips this to STRICT."

log "Peek at the sidecar access log (enabled via meshConfig.accessLogFile)"
run k -n "$NS" logs deploy/inventory-v1 -c istio-proxy --tail=5

log "Phase 3 done. Next: scripts/03-phase4-ingress-gateway.sh"
