#!/usr/bin/env bash
# Shared helpers, sourced by every phase script. Not meant to be run directly.
#   PAUSE=1 script/NN-...sh   -> wait for <enter> between steps (inspect as you go)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Bump ISTIO_VERSION and GATEWAY_API_VERSION together: the Gateway API CRD
# version must be one the pinned Istio release supports (see that release's docs).
export CLUSTER_NAME="${CLUSTER_NAME:-istio-poc}"
export ISTIO_VERSION="${ISTIO_VERSION:-1.27.0}"
export GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.3.0}"
export NS="${NS:-demo}"
export GW_PORT="${GW_PORT:-8080}"
export CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"

export KUBE_CONTEXT="kind-${CLUSTER_NAME}"
export TOOLS_DIR="$ROOT/.tools"
export ISTIO_DIR="$TOOLS_DIR/istio-$ISTIO_VERSION"

# Always pin the kube context so a stray `kubectl config use-context` can't hit the wrong cluster.
k()        { kubectl --context "$KUBE_CONTEXT" "$@"; }
istioctl() { "$ISTIO_DIR/bin/istioctl" --context "$KUBE_CONTEXT" "$@"; }

# Same flags are reused whenever istio is (re)installed, so later phases don't drop earlier settings.
ISTIO_INSTALL_FLAGS=(
  --set profile=minimal                                          # istiod only; ingress comes from Gateway API
  --set meshConfig.accessLogFile=/dev/stdout                     # sidecar access logs: great for learning
  --set meshConfig.defaultConfig.holdApplicationUntilProxyStarts=true  # app container waits for envoy
)

# ---- output helpers ---------------------------------------------------------
# helpers print to stderr so they never pollute pipes like `run k create ... | k apply -f -`
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*" >&2; pause; }
note() { printf '\033[2m    # %s\033[0m\n' "$*" >&2; }
pause() { if [[ "${PAUSE:-0}" == 1 ]]; then read -rp "    [enter] " _ </dev/tty; fi; }
run()   { printf '\033[1;33m+ %s\033[0m\n' "$*" >&2; "$@"; }
runsh() { printf '\033[1;33m+ %s\033[0m\n' "$1" >&2; bash -c "set -o pipefail; $1"; }
try()   { printf '\033[1;33m+ %s\033[0m\n' "$*" >&2; "$@" || printf '    (exit %s, continuing)\n' "$?" >&2; }
require() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null || { echo "missing required tool: $c" >&2; exit 1; }; done
}

# ---- cluster helpers --------------------------------------------------------
# pod_of <ns> <app-label>  -> first pod name
pod_of() { k -n "$1" get pod -l "app=$2" -o jsonpath='{.items[0].metadata.name}'; }

# mesh_curl <ns> <curl args...>  -> run curl from the long-lived `curl` client pod in <ns>
mesh_curl() { k -n "$1" exec deploy/curl -c curl -- curl -sS --max-time 5 "${@:2}"; }

# code_mesh <ns> <url>  -> HTTP status seen from the curl pod in <ns> (000 = connection failed)
code_mesh() { mesh_curl "$1" -o /dev/null -w '%{http_code}' "$2" 2>/dev/null || true; }

# code_gw <path>  -> HTTP status via the ingress gateway port-forward
code_gw() { curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://localhost:${GW_PORT}$1" || true; }

# expect <label> <want> <got>
expect() {
  if [[ "$2" == "$3" ]]; then printf '    \033[32mPASS\033[0m %s (got %s)\n' "$1" "$3"
  else printf '    \033[31mFAIL\033[0m %s (want %s, got %s)\n' "$1" "$2" "$3"; fi
}

# The auto-provisioned gateway Service is type LoadBalancer -> <pending> on kind, so port-forward it.
GW_PF_PID=""
gw_forward_stop() { if [[ -n "$GW_PF_PID" ]]; then kill "$GW_PF_PID" 2>/dev/null || true; fi; }
gw_forward_start() {
  k -n "$NS" port-forward svc/demo-gateway-istio "${GW_PORT}:80" >/dev/null 2>&1 &
  GW_PF_PID=$!
  trap gw_forward_stop EXIT
  local _
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "http://localhost:${GW_PORT}/" && return 0
    sleep 0.5
  done
  echo "gateway port-forward did not come up on :${GW_PORT}" >&2
  return 1
}

export -f k istioctl mesh_curl code_mesh code_gw
