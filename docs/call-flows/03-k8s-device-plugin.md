# Call flow: ROCm/k8s-device-plugin

**Source:** `~/eai-build/k8s-device-plugin/`  
**Script:** `scripts/03-gpu-plugin.sh`

Exposes AMD GPUs to **kubelet** as `amd.com/gpu` — required for the **standard ROCm HIP inference path** (Kaiwo → vLLM pods).

## Downward (registration)

1. **DaemonSet** `amdgpu-device-plugin-daemonset` in `kube-system`.
2. Plugin registers with kubelet device-plugin gRPC socket.
3. **`ListAndWatch`:** discovers GPUs via ROCm/HSA topology.
4. Advertises **`amd.com/gpu`** count on the node.

## gfx1151 environment (DaemonSet)

Applied by `scripts/03-gpu-plugin.sh` in `k8s-ds-gfx1151.yaml`:

| Variable | Purpose |
|----------|---------|
| `HSA_OVERRIDE_GFX_VERSION=11.5.1` | Correct ISA for Strix Halo |
| `HSA_ENABLE_SDMA=0` | Avoid PERMISSION_FAULT on UMA |
| `MIOPEN_FIND_ENFORCE=1` | MIOpen Winograd workaround |
| `PYTORCH_TUNABLEOP_ENABLED=1` | Auto-tune GEMM |
| `TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` | Experimental attention kernels |

## Pod allocation (cluster inference)

5. kubelet **`Allocate`** → plugin sets `/dev/kfd`, `/dev/dri` in container.
6. vLLM/PyTorch pod uses **HIP** inside the container.

## Node labels (Kaiwo scheduling)

Script labels the node:

- `kaiwo/gpu-model=radeon-8060s`
- `kaiwo/nodepool=amd-gfx1151-1gpu`
- `kaiwo/worker=true`

## Upward

- Scheduler sees `amd.com/gpu: 1` in node capacity.
- Failed allocate → pod Pending; check `kubectl logs -n kube-system -l name=amdgpu-dp-ds`.

## Chat prompt path

**On the standard EAI path** when inference runs in a GPU pod. **Not used** for host Vulkan llama-server (direct DRM access).

## Source reading

| Path | Purpose |
|------|---------|
| `internal/pkg/plugin/plugin.go` | gRPC ListAndWatch / Allocate |
| `internal/pkg/amdgpu/amdgpu.go` | `GC_11_5_0` family detection |
| `k8s-ds-gfx1151.yaml` | Generated DaemonSet overlay |
