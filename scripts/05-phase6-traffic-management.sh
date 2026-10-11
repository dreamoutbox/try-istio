#!/usr/bin/env bash
# Phase 6: canary weights, timeouts, fault injection, retries.
source "$(dirname "$0")/lib.sh"
require kubectl curl
gw_forward_start

N="${N:-100}"
versions() { for _ in $(seq 1 "$N"); do curl -s --max-time 5 "http://localhost:${GW_PORT}/orders/sku-1"; done \
             | grep -o '"version":"v[0-9]*"' | sort | uniq -c; }
codes()    { for _ in $(seq 1 "$N"); do curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' "http://localhost:${GW_PORT}/orders/sku-1"; done \
             | sort | uniq -c; }

log "Deploy inventory v2 and DestinationRule subsets (v1/v2 by pod label)"
run k apply -f "$ROOT/k8s/traffic/inventory-v2.yaml" -f "$ROOT/k8s/traffic/destination-rule.yaml"
run k -n "$NS" rollout status deploy/inventory-v2 --timeout=120s

log "No VirtualService yet: plain round-robin over both versions (~50/50)"
echo "+ tally backend version over $N requests" >&2; versions

for w in 90-10 50-50; do
  log "Weighted routing $w"
  run k apply -f "$ROOT/k8s/traffic/vs-weighted-$w.yaml"; sleep 3
  echo "+ tally backend version over $N requests" >&2; versions
done

log "Fault injection + timeout: 3s delay injected, route timeout 1s -> expect failures after ~1s"
run k apply -f "$ROOT/k8s/traffic/vs-fault-delay.yaml"; sleep 3
runsh "time curl -s -o /dev/null -w '%{http_code}\n' localhost:$GW_PORT/orders/sku-1"
note "Envoy gives up at 1s with 504; orders turns that into an error for its caller."

log "Retries: make v2 flaky (FAIL_RATE=0.5) and send 100% of traffic to it"
run k -n "$NS" set env deploy/inventory-v2 FAIL_RATE=0.5
run k -n "$NS" rollout status deploy/inventory-v2 --timeout=120s
run k apply -f "$ROOT/k8s/traffic/vs-v2-only.yaml"; sleep 3
note "Without retries, expect roughly half failures:"
echo "+ tally HTTP status over $N requests" >&2; codes
run k apply -f "$ROOT/k8s/traffic/vs-v2-retry.yaml"; sleep 3
note "attempts=3 on 5xx, expect ~1/8 failures:"
echo "+ tally HTTP status over $N requests" >&2; codes
note "Injected faults are NOT retried (fault filter runs before the router), hence a really flaky upstream."

log "Reset to a clean state"
run k delete -f "$ROOT/k8s/traffic/vs-v2-retry.yaml" --ignore-not-found
run k -n "$NS" set env deploy/inventory-v2 FAIL_RATE=0
try istioctl proxy-config routes "deploy/orders.$NS" --name 80

log "Phase 6 done. Next: script/06-phase7-observability.sh"
