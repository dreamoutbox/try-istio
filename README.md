# Istio Service Mesh POC on kind

Two Go backend services (`orders` -> `inventory`) deployed on a local kind cluster in Istio sidecar mode. Designed to demonstrate and verify mTLS, zero-trust authorization, Gateway API ingress, traffic routing, fault resilience, and distributed observability.

## Prerequisites

- Docker daemon running
- `kind` (Kubernetes in Docker)
- `kubectl`
- `go` (>= 1.22)
- `curl`

## Quickstart

Run the full end-to-end pipeline:

```bash
./scripts/all.sh
```

Or run step-by-step with pauses between commands:

```bash
PAUSE=1 ./scripts/00-phase1-setup-kind-and-istio.sh
```

To clean up resources:

```bash
./scripts/99-teardown.sh
# or CLEAN=1 ./scripts/99-teardown.sh to also remove downloaded binaries in .tools/
```

## Structure

```
scripts/           Automated shell scripts for each phase and common lib
cmd/orders/        Orders service implementation and tests
cmd/inventory/     Inventory service implementation and tests
internal/server/   Shared HTTP server lifecycle with graceful shutdown
internal/tracing/  Shared W3C and B3 trace header propagation
build/Dockerfile   Multi-stage distroless Dockerfile
k8s/base/          Base manifests (namespace, serviceaccounts, deployments, services)
k8s/mesh/          Gateway API ingress and mTLS/Authz policies
k8s/traffic/       Canary, timeout, fault injection, and retry policies
k8s/observability/ Telemetry resource configuration
```

## Phase Walkthrough

### Phase 1: kind Cluster and Istio Control Plane
- Script: `scripts/00-phase1-setup-kind-and-istio.sh`
- What to look at:
  - Gateway API CRDs installed prior to istiod startup.
  - Minimal profile Istio control plane running with access logging enabled.
  - GatewayClass `istio` recognized by the controller.

### Phase 2: Services Without Mesh
- Script: `scripts/01-phase2-build-and-deploy-services.sh`
- What to look at:
  - Direct DNS resolution between `orders` and `inventory` in namespace `demo`.
  - Distroless non-root containers running with explicit probes and resource limits.
  - Combined JSON response returned over plain Service DNS.

### Phase 3: Sidecar Injection and Automatic mTLS
- Script: `scripts/02-phase3-enable-sidecar-and-mtls.sh`
- What to look at:
  - Workload pods transition from 1/1 to 2/2 containers (`istio-proxy` injected).
  - SPIFFE identity present in `X-Forwarded-Client-Cert` (`URI=spiffe://cluster.local/ns/demo/sa/orders`).
  - PERMISSIVE mode accepting both mTLS callers and legacy plaintext callers.

### Phase 4: Ingress via Gateway API
- Script: `scripts/03-phase4-ingress-gateway.sh`
- What to look at:
  - `Gateway` resource `demo-gateway` automatically provisions `demo-gateway-istio`.
  - `HTTPRoute` directing `/orders` to Service `orders:80`.
  - Verification that unknown paths return 404 from the gateway.

### Phase 5: STRICT mTLS and Zero-Trust Authorization
- Script: `scripts/04-phase5-authz-policies.sh`
- What to look at:
  - `PeerAuthentication` mode STRICT rejecting plaintext connections.
  - Empty `AuthorizationPolicy` enforcing default-deny across the namespace.
  - Least-privilege allow policies granting access only to expected identities (`demo-gateway-istio` -> `orders`, `orders` -> `inventory`).

### Phase 6: Traffic Management
- Script: `scripts/05-phase6-traffic-management.sh`
- What to look at:
  - Canary weighting across `v1` and `v2` subsets (90/10 and 50/50).
  - Route-level fault delay (3s) combined with a 1s timeout failing at ~1s.
  - Upstream retries (3 attempts on 5xx) reducing failure rate on flaky endpoints from ~50% to ~10%.

### Phase 7: Distributed Observability
- Script: `scripts/06-phase7-observability.sh`
- What to look at:
  - Prometheus, Kiali, and Jaeger addons deployed to `istio-system`.
  - Telemetry API configuring 100% trace sampling.
  - Distributed trace spanning `demo-gateway-istio` -> `orders.demo` -> `inventory.demo`.
  - Dashboards accessible via `istioctl dashboard kiali` and `istioctl dashboard jaeger`.
