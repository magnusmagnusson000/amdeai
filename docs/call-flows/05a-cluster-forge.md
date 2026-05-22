# Call flow: silogen/cluster-forge

**Source:** `~/eai-build/cluster-forge/`

GitOps **installer** — not in runtime inference path after bootstrap.

## Downward (operator intent → cluster state)

1. **`go run . smelt`** — reads `input/config.yaml`, normalizes charts/YAML into `working/`.
2. **`go run . cast`** — packages bundle into deployable OCI artefact.
3. **`scripts/bootstrap.sh`** — installs ArgoCD, Gitea, Keycloak, MinIO, CNPG, Kaiwo chart refs, etc.
4. **ArgoCD** syncs Applications → Kubernetes creates Deployments/Services.

## Chat prompt path

**None at inference time.** cluster-forge only shapes **what is installed** (including Kaiwo, ArgoCD UI).

## Upward (observability)

- ArgoCD UI shows sync/health (see Playwright e2e).
- `kubectl get applications -n argocd`

## Source reading order

| Path | Purpose |
|------|---------|
| `main.go` / CLI | smelt, cast commands |
| `input/config.yaml` | component toggles |
| `working/` | generated manifests (after smelt) |
