# Call flow: silogen/kaiwo

**Source:** `~/eai-build/kaiwo/`

**Workload orchestrator** for AI jobs on Kubernetes — active when inference runs **inside GPU pods**, not for host `llama-server`.

## Downward (job submission → pod)

1. User or CI creates **KaiwoJob** (CRD) or higher-level wrapper referencing GPU + image.
2. **kaiwo-controller-manager** reconciles:
   - Checks node labels: `kaiwo/worker`, `kaiwo/gpu-model`, topology labels.
   - Integrates **Kueue** `ClusterQueue` / `ResourceFlavor` `amd-gfx1151`.
3. **Kueue** admits workload when `amd.com/gpu` quota available.
4. **kube-scheduler** binds pod to node with device plugin resource.
5. **kubelet** allocates `amd.com/gpu` via device plugin socket.
6. Container starts (e.g. vLLM image) → **ROCm HIP** path inside pod.

## Chat prompt path (cluster inference variant)

If chat went through a Kaiwo-managed vLLM Service instead of host llama.cpp:

Browser → Ingress → KServe/Service → **Pod: vLLM** → HIP → ROCm → amdgpu → hardware.

**This stack’s Gemma 4 local path bypasses Kaiwo** for tokens.

## Upward (status → user)

- KaiwoJob status: phases, pod names, failures (e.g. SchedulingGated if labels missing).
- Events explain TAS/topology gates.

## Source reading order

| Path | Purpose |
|------|---------|
| `cmd/kaiwo/` | CLI |
| `internal/controller/` | Reconcilers |
| `config/crd/` | CRD manifests |
| `Makefile` | `docker-build`, `deploy` |
