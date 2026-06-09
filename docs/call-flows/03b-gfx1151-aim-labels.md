# Call flow: gfx1151 AIM accelerator labels

**Script:** `scripts/03b-gfx1151-aim-labels.sh`  
**Invoked by:** `scripts/08-gemma4-31b.sh` (and any gfx1151 AIM deploy)

## Problem

Cluster Bloom labels the Z13 node as `MI300X` for Cluster Forge compatibility. AIM Engine template auto-selection looks for `feature.node.kubernetes.io/aim-accelerator.{GPU}` labels written by the AcceleratorDetector DaemonSet, which only detects Instinct MI-series GPUs today.

Without an `aim-accelerator.R9700` label, every `AIMClusterModel` reports `NoTemplatesAvailable` and managed `AIMService` resources cannot schedule.

## Fix

Map Strix Halo (gfx1151, PCI device `0x1586`) to AIM accelerator class **R9700** (Radeon AI Pro), supported since AIM Engine v0.2.4:

```bash
bash scripts/03b-gfx1151-aim-labels.sh
```

Labels applied:

| Label | Value | Purpose |
|-------|-------|---------|
| `feature.node.kubernetes.io/aim-accelerator.R9700` | `1` | v1alpha2 profile node affinity (Exists) |
| `amd.com/gpu.device-id` | `7551` | AIM catalog template matching (R9700 PCI ID) |
| `amdeai.com/gpu.device-id.actual` | `1586` | Actual Strix Halo gfx1151 PCI ID |
| `amd.com/gpu.vram` | `128G` | Unified memory pool hint |
| `kaiwo/gpu-model` | `gfx1151` | Kaiwo topology scheduling |

Also writes an NFD feature file under `/etc/kubernetes/node-feature-discovery/features.d/aim-accelerator-gfx1151` when accessible.

## Verify

```bash
kubectl get node -o json | jq -r '.items[0].metadata.labels | to_entries[] | select(.key | contains("aim-accelerator")) | "\(.key)=\(.value)"'
kubectl get aimclusterprofile google-gemma-4-31b-r9700-latency -o jsonpath='{.status.matchingNodes}{"\n"}{.status.status}{"\n"}'
```

Expected: `matchingNodes` ≥ 1, profile `Ready`.
