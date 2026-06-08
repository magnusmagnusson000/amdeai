# Call flow: silogen/cluster-bloom

**Source:** `~/eai-build/cluster-bloom/`  
**Config:** [bloom-gfx1151.yaml](../../bloom-gfx1151.yaml)  
**Guide:** [BLOOM_GFX1151_INSTALL.md](../BLOOM_GFX1151_INSTALL.md)

Declarative **RKE2 + ROCm + Cluster Forge** installer. Replaces scripts `00`–`06b` for the official gfx1151 path.

## Workflow (gfx1151)

```bash
NODE_IP=$(hostname -I | awk '{print $1}')
# edit bloom-gfx1151.yaml: DOMAIN: "${NODE_IP}.nip.io"
sudo ./bloom cli bloom-gfx1151.yaml
# reboot if GRUB/env changed, then re-run bloom
```

## Bloom phases (Ansible tags)

| Phase | Tag | Equivalent amdeai script |
|-------|-----|--------------------------|
| Validate node | `validate_node` | `00-prerequisites.sh` (partial) |
| Prepare node | `prepare_node` | `01-host-rocm.sh` (when `GPU_GFX1151`) |
| Deploy cluster | `deploy_cluster` | `02-kubernetes.sh` (RKE2 not k3s) |
| Deploy k8s apps | `deploy_k8s_apps` | `03-gpu-plugin.sh`, `04-platform.sh` (partial) |
| Deploy ClusterForge | `deploy_clusterforge` | `05a-cluster-forge.sh` + `05b-kaiwo.sh` + `06a` + `06b` |

## gfx1151-specific tasks (`GPU_GFX1151: true`)

- `prepare_node/gpu_rocm_gfx1151.yaml` — ROCm 7.2.3 apt install
- `prepare_node/gpu_grub_gfx1151.yaml` — unified memory GRUB
- `prepare_node/gpu_env_gfx1151.yaml` — HSA_OVERRIDE_GFX_VERSION etc.
- `deploy_k8s_apps/gpu_device_plugin_gfx1151.yaml` — DaemonSet + Kaiwo labels

## Chat prompt path

**None at inference time.** Bloom is install-time only. After bootstrap, inference follows the standard Kaiwo → vLLM → HIP path in [CALL_FLOW_OVERVIEW.md](../CALL_FLOW_OVERVIEW.md).

## Upward

- Export playbook for inspection: `./bloom cli bloom-gfx1151.yaml --export`
- Cluster Bloom source: `~/eai-build/cluster-bloom` branch `feat/gfx1151-support`
