# Call flow: silogen/kaiwo

**Source:** `~/eai-build/kaiwo/`  
**Script:** `scripts/05b-kaiwo.sh`

**Standard EAI workload orchestrator** — schedules GPU inference pods (vLLM, Ray, training) on gfx1151 nodes.

## Downward (job → pod → HIP)

1. User or API creates **KaiwoJob** with GPU count and container image.
2. **kaiwo-controller** reconciles; submits to **Kueue** `ClusterQueue` / flavor `amd-gfx1151`.
3. **Kueue** admits when `amd.com/gpu` quota available.
4. **Scheduler** binds pod to node with `kaiwo/gpu-model=radeon-8060s`.
5. **Device plugin** allocates GPU; container mounts `/dev/kfd`, `/dev/dri`.
6. **vLLM / PyTorch** runs **ROCm HIP** inference.

## ROCm env in GPU pods

Inherit from node/DaemonSet or set explicitly in KaiwoJob pod spec:

```yaml
env:
  - name: HSA_OVERRIDE_GFX_VERSION
    value: "11.5.1"
  - name: HSA_ENABLE_SDMA
    value: "0"
  - name: MIOPEN_FIND_ENFORCE
    value: "1"
```

## Chat prompt path (standard cluster inference)

```
Browser → AIWB → KaiwoJob → GPU pod (vLLM) → HIP → KFD → gfx1151 → tokens
```

**Local Gemma** via host llama-server **bypasses Kaiwo** for tokens; Kaiwo remains installed for other models and workloads.

## ResourceFlavor (this stack)

Created by `05b-kaiwo.sh`:

- Flavor: `amd-gfx1151`
- Quota: `amd.com/gpu: 1`, CPU/memory limits for single-node Z13

## Source reading

| Path | Purpose |
|------|---------|
| `internal/controller/` | Reconcilers |
| `pkg/workloads/common/podspec.go` | GPU affinity |
| `workloads/inference/LLMs/` | Sample vLLM KaiwoJobs |
