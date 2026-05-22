# Call flow: amd-enterprise-ai/aim-engine

**Source:** `~/eai-build/aim-engine/`

Kubernetes **operator** for inference lifecycle and routing — control plane adjacent to the chat hot path.

## Downward (configuration → runtime)

1. **Helm install** applies `dist/crds.yaml` → API server registers `AIMModel`, routing CRDs.
2. **Controller manager** (`cmd/main.go` or `main.go` under operator layout) watches CRs via controller-runtime.
3. On `AIMModel` create/update:
   - Validates `spec.endpoint` (URL, type OpenAI).
   - May configure **Gateway API** routes (`clusterRuntimeConfig.spec.routing.enabled`) for in-cluster backends.
   - For **external host endpoint** (our llama-server), effect is primarily **registration** — no pod spawn.

## Chat prompt path involvement

For local Gemma endpoint:

- Workbench reads **AIMModel** → HTTP to host.
- AIM Engine is **not** in the per-token loop unless routing sends traffic through an AIM-managed gateway Service.

## Upward (status)

- Operator writes **status** subresource: conditions (Ready), observed generation.
- Events recorded on CR for debugging (`kubectl describe aimmodel`).

## Source reading order

| Order | Area |
|-------|------|
| 1 | `api/` — CRD Go types |
| 2 | `internal/controller/` — reconcile loops |
| 3 | `dist/chart/templates/` — deployment, RBAC, webhooks |

## Build artefacts

- `make crds` → `dist/crds.yaml`
- `make helm` → `dist/chart/`
