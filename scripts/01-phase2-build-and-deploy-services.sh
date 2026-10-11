#!/usr/bin/env bash
# Phase 2: build the two Go services, load into kind, deploy WITHOUT the mesh.
source "$(dirname "$0")/lib.sh"
require docker kind kubectl

IMAGE_TAG="${IMAGE_TAG:-0.1.0}"

log "Build images (one Dockerfile, SERVICE build-arg selects cmd/<service>)"
for svc in orders inventory; do
  run docker build -f "$ROOT/build/Dockerfile" --build-arg SERVICE="$svc" -t "$svc:$IMAGE_TAG" "$ROOT"
done

log "Load images into kind (no registry needed)"
run kind load docker-image --name "$CLUSTER_NAME" "orders:$IMAGE_TAG" "inventory:$IMAGE_TAG"
note "Manifests use imagePullPolicy: IfNotPresent and an explicit tag, otherwise kind tries to pull."

log "Deploy plain Kubernetes objects (namespace has NO istio-injection label yet)"
run k apply -f "$ROOT/k8s/base/"
run k -n "$NS" rollout status deploy/inventory-v1 --timeout=120s
run k -n "$NS" rollout status deploy/orders --timeout=120s
run k -n "$NS" get pods,svc -o wide
run k get ns "$NS" --show-labels

log "Smoke test: orders -> inventory over plain Service DNS, from a throwaway pod"
run k -n "$NS" run curl-smoke --rm -i --restart=Never --image="$CURL_IMAGE" --command -- \
  curl -sS --max-time 5 http://orders/orders/sku-1
run k -n "$NS" logs deploy/orders --tail=5

log "Phase 2 done. Next: scripts/02-phase3-enable-sidecar-and-mtls.sh"
