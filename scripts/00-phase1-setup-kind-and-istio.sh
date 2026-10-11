#!/usr/bin/env bash
# Phase 1: kind cluster + Gateway API CRDs + Istio control plane. Idempotent.
source "$(dirname "$0")/lib.sh"

log "Preflight"
require docker kind kubectl curl
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable" >&2; exit 1; }

log "Fetch istioctl $ISTIO_VERSION into .tools/ (also gives us samples/addons for phase 7)"
if [[ ! -x "$ISTIO_DIR/bin/istioctl" ]]; then
  mkdir -p "$TOOLS_DIR"
  (cd "$TOOLS_DIR" && curl -fsSL https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh -)
else
  note "already present: $ISTIO_DIR"
fi
run "$ISTIO_DIR/bin/istioctl" version --remote=false

log "Create kind cluster '$CLUSTER_NAME' (single node keeps RAM low)"
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  note "cluster exists, skipping create"
else
  run kind create cluster --name "$CLUSTER_NAME" --config=- <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
fi
run k get nodes -o wide

log "Install Gateway API CRDs $GATEWAY_API_VERSION"
note "Istio does not ship these. They must exist before istiod starts, or istiod needs a restart to enable its Gateway controller."
run k apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
runsh "k get crd -o name | grep gateway.networking.k8s.io"

log "Install Istio $ISTIO_VERSION control plane (profile=minimal -> istiod only)"
note "Flags live in lib.sh (ISTIO_INSTALL_FLAGS) and are reused by later phases."
run istioctl install -y "${ISTIO_INSTALL_FLAGS[@]}"
run k -n istio-system rollout status deploy/istiod --timeout=180s

log "Inspect what got installed"
run k get pods -n istio-system
run istioctl version
try istioctl verify-install
runsh "k get crd -o name | grep -E 'istio.io|gateway.networking.k8s.io'"
note "GatewayClass 'istio' appears once istiod sees the Gateway API CRDs:"
run k get gatewayclass
note "The sidecar injector is just a mutating webhook:"
run k get mutatingwebhookconfigurations
note "Effective mesh config (accessLogFile, holdApplicationUntilProxyStarts):"
runsh "k -n istio-system get cm istio -o jsonpath='{.data.mesh}'"

log "Phase 1 done. Next: script/01-phase2-build-and-deploy-services.sh"
