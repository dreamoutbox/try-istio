# PLAN: Istio service mesh POC on kind (Go, backend-to-backend)

Scope: two Go backend services, `orders` → `inventory`, on a local kind cluster with Istio sidecar mode. Purpose is to inspect, learn and try: mTLS, authorization, ingress, traffic shifting, resilience, observability.

Shell scripts for each phase are already written in `script/`. App code, Dockerfile and manifests are what the phases below build. Scripts only apply the files named in each phase.

## Layout

```
script/            one script per phase (numbered from 00), lib.sh, all.sh, 99-teardown.sh
cmd/orders/        main.go
cmd/inventory/     main.go
build/Dockerfile   one multi-stage Dockerfile, ARG SERVICE selects cmd/<service>
k8s/base/          00-namespace.yaml, serviceaccounts.yaml, orders.yaml, inventory-v1.yaml
k8s/mesh/          gateway.yaml, peer-auth-strict.yaml, authz-deny-all.yaml, authz-allow.yaml
k8s/traffic/       inventory-v2.yaml, destination-rule.yaml, vs-weighted-90-10.yaml, vs-weighted-50-50.yaml,
                   vs-fault-delay.yaml, vs-v2-only.yaml, vs-v2-retry.yaml
k8s/observability/ telemetry.yaml
.tools/            downloaded istioctl + addon samples (gitignored)
```

Script conventions: `lib.sh` pins the kube context (`kind-istio-poc`), prints every command before running it (`+ ...`), and supports `PAUSE=1` to stop between steps. Versions are overridable env vars: `ISTIO_VERSION`, `GATEWAY_API_VERSION`, `CLUSTER_NAME`, `NS`.

## Service contract (used by the scripts)

- `inventory`: `GET /stock/{sku}` → compact one-line JSON `{"sku","qty","version","pod","xfcc"}`; `version` from env `VERSION`, `pod` from `HOSTNAME`, `xfcc` echoes the `X-Forwarded-Client-Cert` request header. Env `FAIL_RATE` (0–1) returns 503 with that probability. `/healthz`.
- `orders`: `GET /orders/{sku}` calls `INVENTORY_URL` (default `http://inventory/stock/{sku}`), returns `{"sku","inventory":{...inventory JSON...}}`. Client timeout 2s, built with `http.NewRequestWithContext`. Forwards trace headers (`x-request-id`, `traceparent`, `tracestate`, `x-b3-*`) to inventory. Returns 502 if inventory fails. `/healthz`.
- Both: Go ≥ 1.22 stdlib only (`http.ServeMux` method+wildcard patterns, `log/slog`), explicit `http.Server` timeouts, graceful shutdown on SIGTERM via `signal.NotifyContext`.
- Kubernetes: one Deployment per version (`inventory-v1`, later `inventory-v2`), shared Service `inventory` selecting `app=inventory` only. Each Deployment has its own ServiceAccount (`orders`, `inventory`). Probes, resource requests/limits, `imagePullPolicy: IfNotPresent`, explicit image tag (no `:latest`).

### Phase 1: kind cluster + Gateway API CRDs + Istio control plane [STATUS: DONE]
- Goal: Single-node kind cluster with Gateway API CRDs and a healthy istiod.
- Script: `script/00-phase1-setup-kind-and-istio.sh` (written)
  - fetch pinned `istioctl` into `.tools/`, create kind cluster, apply Gateway API CRDs, `istioctl install` (profile `minimal`, access logs on, `holdApplicationUntilProxyStarts`), then inspect CRDs, GatewayClass, injector webhook, mesh config
- Tasks:
  - [x] Run the script; read through each inspect step
  - [x] Confirm re-running is a no-op (idempotent)
- Done when: `istiod` Ready, `istioctl verify-install` clean, `kubectl get gatewayclass` shows `istio`, `script/99-teardown.sh` then script 00 reproduces it.

### Phase 2: Two Go services, no mesh [STATUS: DONE]
- Goal: `orders` calls `inventory` over plain Service DNS.
- Script: `script/01-phase2-build-and-deploy-services.sh` (written): docker build both images, `kind load`, apply `k8s/base/`, smoke test from a throwaway pod
- Tasks:
  - [x] `cmd/inventory/main.go` and `cmd/orders/main.go` per the contract above
  - [x] Table-driven `httptest` tests for both handlers (success, upstream failure, timeout, FAIL_RATE)
  - [x] `build/Dockerfile`: `golang` build stage with `CGO_ENABLED=0`, `gcr.io/distroless/static:nonroot` runtime
  - [x] `k8s/base/` manifests (namespace `demo` WITHOUT injection label; file `00-` prefix so it applies first)
- Done when: `go test ./...` passes; script 01 prints orders JSON that embeds inventory JSON.

### Phase 3: Sidecar injection + automatic mTLS [STATUS: DONE]
- Goal: Both services in the mesh; prove traffic is mTLS while still PERMISSIVE.
- Script: `script/02-phase3-enable-sidecar-and-mtls.sh` (written): label namespace, restart, create `curl` client pods (meshed in `demo`, non-meshed in `legacy`), then 4 proofs (SPIFFE identity in `xfcc`, `istioctl x describe`, workload certs, plaintext from `legacy` still accepted)
- Tasks:
  - [x] Run the script; compare pod container lists before and after
  - [x] Note the `xfcc` value contains `spiffe://cluster.local/ns/demo/sa/orders`
- Done when: pods show 2/2; `xfcc` present for meshed callers and empty for `legacy`.

### Phase 4: Ingress via Gateway API [STATUS: DONE]
- Goal: Reach `orders` from the host through an Istio-managed gateway.
- Script: `script/03-phase4-ingress-gateway.sh` (written): apply gateway, wait for the auto-created `demo-gateway-istio` Deployment, port-forward, curl, inspect with `proxy-status` / `proxy-config routes`
- Tasks:
  - [x] `k8s/mesh/gateway.yaml`: `Gateway` named `demo-gateway` (gatewayClassName `istio`, listener HTTP 80, routes from same namespace) + `HTTPRoute` `/orders` → Service `orders:80`
- Done when: `curl localhost:8080/orders/sku-1` returns the combined JSON; unknown path returns 404 from the gateway.

### Phase 5: STRICT mTLS + zero-trust authorization [STATUS: DONE]
- Goal: Only the intended identities can call each service.
- Script: `script/04-phase5-authz-policies.sh` (written): staged apply with PASS/FAIL checks at each stage (baseline → STRICT → deny-all → allow rules), then reads the denying sidecar's log
- Tasks:
  - [x] `peer-auth-strict.yaml`: `PeerAuthentication` STRICT in `demo`
  - [x] `authz-deny-all.yaml`: empty-spec `AuthorizationPolicy`
  - [x] `authz-allow.yaml`: gateway SA (`demo-gateway-istio`) → `orders`; `orders` SA → `inventory`, GET only
- Done when: all `expect` lines PASS: legacy plaintext rejected, meshed `curl` SA gets 403 on both services, gateway path returns 200.

### Phase 6: Traffic management [STATUS: TODO]
- Goal: Canary, timeout, fault injection, retries, all without touching Go code.
- Script: `script/05-phase6-traffic-management.sh` (written): deploy v2, tally versions at default / 90-10 / 50-50, delay fault + 1s timeout, flaky v2 with and without retries, reset
- Tasks:
  - [ ] `inventory-v2.yaml` (label `version: v2`, `VERSION=v2`, `FAIL_RATE=0`)
  - [ ] `destination-rule.yaml` subsets `v1`/`v2`
  - [ ] VirtualService `inventory` variants (all named `inventory`, so each apply replaces the last): weighted 90/10 and 50/50, delay fault (3s, 100%) with `timeout: 1s`, v2-only, v2-only + `retries` (attempts 3, `retryOn: 5xx`, `perTryTimeout: 1s`)
- Done when: version tallies track the weights; delayed request fails near 1s; failure rate drops from ~50% to ~12% with retries.

### Phase 7: Observability [STATUS: TODO]
- Goal: See the mesh graph and a trace spanning both services.
- Script: `script/06-phase7-observability.sh` (written): install Prometheus/Kiali/Jaeger from the local release's `samples/addons`, register Jaeger as an extension provider (re-runs `istioctl install` with the same flags + overlay), apply Telemetry, generate load, print dashboard commands
- Tasks:
  - [ ] `k8s/observability/telemetry.yaml`: `Telemetry` in `demo` with tracing provider `jaeger` at 100% sampling and access logging provider `envoy`
  - [ ] Verify `orders` forwards trace headers
- Done when: Kiali shows `gateway → orders → inventory` with mTLS locks; Jaeger shows a trace under `orders.demo` with spans from both services.

### Phase 8: Polish and teardown [STATUS: TODO]
- Goal: Fresh clone → running demo in minutes.
- Script: `script/99-teardown.sh` (delete cluster; `CLEAN=1` also removes `.tools/`), `script/all.sh` (runs 00–06 in order) (both written)
- Tasks:
  - [ ] README: prerequisites (docker, kind, kubectl, go), quickstart, one section per phase with "what to look at"
  - [ ] Add `.tools/` to `.gitignore`
  - [ ] Optional stretch: ambient mode on a branch, compare resource use and what `istioctl` shows
- Done when: `script/all.sh` succeeds on a clean machine and every PASS line in phase 5 is green.

## Unknowns, risks, assumptions
- Scripts are syntax-checked only (`bash -n`), not run against a live cluster. Expect small fixes on first run.
- `ISTIO_VERSION` defaults to 1.27.0 with Gateway API CRDs v1.3.0 (a pairing documented for 1.27). I could not confirm the latest Istio release; if you bump Istio, bump the CRDs together.
- kind has no external LB, so the gateway Service stays `<pending>` and the Gateway may not report `Programmed`. Scripts port-forward instead. Alternative: cloud-provider-kind or MetalLB.
- Injected faults are not retried (fault filter runs before the router), so the retry demo uses a genuinely flaky Go upstream (`FAIL_RATE`).
- Jaeger addon must expose OTLP on `jaeger-collector:4317`; phase 7 prints the service to check. If absent, switch the provider to zipkin on 9411.
- Addons are sample-grade: no persistence, no auth. Demo only.
- Single kind node; Istio plus addons needs roughly 4 GB free for Docker.
- Assumed sidecar mode. Phase 3 tests need the `legacy` namespace and `curl` client pods created by script 02.
