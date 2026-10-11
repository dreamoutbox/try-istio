#!/usr/bin/env bash
# Phase 7: Prometheus + Kiali + Jaeger (Istio sample addons, demo-grade) and tracing config.
source "$(dirname "$0")/lib.sh"
require kubectl curl

log "Install sample addons from the local istio $ISTIO_VERSION release (version-matched)"
for a in prometheus kiali jaeger; do run k apply -f "$ISTIO_DIR/samples/addons/$a.yaml"; done
for d in prometheus kiali jaeger; do run k -n istio-system rollout status "deploy/$d" --timeout=240s; done
run k -n istio-system get svc jaeger-collector

log "Register Jaeger as a tracing extension provider (meshConfig change = re-run install with the SAME flags)"
cat > "$TOOLS_DIR/tracing-overlay.yaml" <<'EOF'
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    extensionProviders:
      - name: jaeger
        opentelemetry:
          service: jaeger-collector.istio-system.svc.cluster.local
          port: 4317
EOF
run istioctl install -y -f "$TOOLS_DIR/tracing-overlay.yaml" "${ISTIO_INSTALL_FLAGS[@]}"
run k -n istio-system rollout status deploy/istiod --timeout=180s

log "Enable tracing (100% sampling, demo only) and access logs via the Telemetry API"
run k apply -f "$ROOT/k8s/observability/telemetry.yaml"

log "Generate load through the gateway"
gw_forward_start
for _ in $(seq 1 200); do curl -s -o /dev/null "http://localhost:${GW_PORT}/orders/sku-1"; sleep 0.1; done
note "Reminder: orders must forward trace headers (traceparent, x-request-id, x-b3-*) to inventory, or traces will not join."

log "Open the UIs (each command blocks; run in its own terminal)"
IC="$ISTIO_DIR/bin/istioctl --context $KUBE_CONTEXT"
cat <<EOF
  Kiali  (graph: gateway -> orders -> inventory, mTLS locks):  $IC dashboard kiali
  Jaeger (search service 'orders.$NS', expect 2+ spans):       $IC dashboard jaeger
  Prometheus (query: istio_requests_total):                    $IC dashboard prometheus
EOF

log "Phase 7 done. Teardown: script/99-teardown.sh"
