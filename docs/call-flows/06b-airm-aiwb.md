# Call flow: AMD AI Workbench + AIRM (UI and control plane)

**Deploy:** Helm OCI charts (`airm`, `aiwb`) — application source is not public; flow is inferred from architecture and CRDs.

## Chat prompt entry (top of stack)

1. **Browser** loads `https://aiwbui.<DOMAIN>` (TLS terminated by in-cluster ingress / cert-manager).
2. **Keycloak** SSO: user `silogen-admin` obtains session cookie / OIDC token.
3. **AI Workbench SPA** sends authenticated API calls to workbench backend (REST/GraphQL — internal to chart).

## Model resolution (downward)

4. User selects **Gemma 4 26B-A4B (local)** in Chat UI.
5. Backend queries **Kubernetes API** (or cached informer) for `AIMModel` CR `gemma-4-26b-a4b-local`:
   - `spec.endpoint.url` → `http://<node-ip>:8080`
   - `spec.endpoint.type` → `OpenAI`
6. Backend (or AIM Engine sidecar/gateway) constructs OpenAI client targeting that URL.
7. **HTTP leaves cluster** to host `llama-server` (MetalLB not required for host IP; may use host network or direct node IP).

AIRM (`airmui.<DOMAIN>`) is parallel: GPU inventory, policies, health — **not** typically in per-token inference for this local endpoint unless workbench delegates quota checks to AIRM APIs first.

## Response path (upward)

8. `llama-server` returns tokens (see [07-llama-cpp.md](07-llama-cpp.md)).
9. Workbench backend normalizes to UI message model (role, content, timestamps).
10. UI renders markdown/stream; WebSocket or SSE from backend to browser.

## Relation to AIM Engine

- **AIMModel CR** is the contract between Workbench and inference URL.
- AIM Engine operator ensures CRDs exist and routing config; hot path may be direct HTTP from workbench to llama-server once CR is read.

## What to read on this machine

- `kubectl describe aimmodel gemma-4-26b-a4b-local`
- Helm values used at install: `helm get values aiwb -n aiwb`
- Pod logs: `kubectl logs -n aiwb -l app.kubernetes.io/name=aiwb --tail=200`
