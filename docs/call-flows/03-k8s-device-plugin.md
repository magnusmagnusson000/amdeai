# Call flow: ROCm/k8s-device-plugin

**Source:** `~/eai-build/k8s-device-plugin/`

Exposes AMD GPUs to **kubelet** for Kubernetes scheduling — parallel to host Vulkan used by llama.cpp.

## Downward (registration)

1. **DaemonSet pod** starts on node (`amdgpu-device-plugin-daemonset`).
2. Binary connects to kubelet **device plugin gRPC socket** (`/var/lib/kubelet/device-plugins/`).
3. **`ListAndWatch`**: discovers GPUs via ROCm/HSA (with `HSA_OVERRIDE_GFX_VERSION=11.5.1` in pod env).
4. Advertises extended resource **`amd.com/gpu`** count to kubelet.
5. kubelet updates **Node.status.capacity/allocatable**.

## Pod allocation (when Kaiwo/vLLM pod scheduled)

6. kubelet **`Allocate`** RPC → plugin sets device nodes/env in container spec.
7. Container runtime bind-mounts `/dev/kfd`, `/dev/dri`, ROCm libs.
8. In-container inference uses **HIP/ROCm**, not the host Vulkan llama path.

## Upward (to scheduler)

- Node labels applied by `03-gpu-plugin.sh` feed **Kaiwo** topology scheduler.
- Failed allocate → pod stays Pending / ContainerCreating with device plugin errors in logs.

## Source reading order

| Path | Purpose |
|------|---------|
| `cmd/` or main device plugin package | gRPC service impl |
| `Dockerfile` | image build |
| `k8s-ds-gfx1151.yaml` | local DaemonSet overlay |

## Chat prompt path

**Only if** chat is served from a GPU pod. **Not used** for host `llama-server` Vulkan path.
