# DiffusionGemma 26B managed AIMService on gfx1151 — post-Bloom install guide

**Audience:** Host with a working Cluster Bloom installation ([BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md)).

> **Generic catalog playbook:** [AIM_CATALOG_MODEL_DEPLOY_GFX1151.md](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md). This document is the **DiffusionGemma-specific** deep dive.

**Goal:** Deploy `google/diffusiongemma-26B-A4B-it` as a managed `AIMService` on gfx1151 (Radeon 8060S / R9700). DiffusionGemma is a discrete diffusion LLM (dLLM) on the Gemma 4 MoE backbone — vLLM serves it with block-diffusion denoising, not standard autoregressive decoding.

**Pattern:** Same custom AIM image strategy as Qwen ([QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md)): `aim-runtime` from `aim-base:0.11` layered onto `kyuz0/vllm-therock-gfx1151` (vLLM 0.22+ with `--diffusion-config`). Do **not** use `:stable` for DiffusionGemma.

---

## Status on this cluster (2026-06-21)

| Item | State |
|------|-------|
| Catalog CRs + template discovery fix | Working (`fix-diffusiongemma-template-discovery.sh`) |
| Weights (`AIMArtifact`) | Downloaded (~48 GiB PVC) |
| Custom AIM image | Built: `{hostname}:32000/aim-gfx1151-diffusiongemma-26b:0.11-therock` |
| Inference (predictor) | **Paused by default** (`minReplicas=0`) — see freeze section |
| Performance benchmark | **Not obtained** — blocked by gfx1151 KFD/MES stall during GPU load |
| E2E Deploy + Chat (Playwright) | Blocked until inference runs stably |

---

## gfx1151 freeze investigation (critical)

Repeated **full desktop freezes** occurred when DiffusionGemma vLLM started loading on gfx1151 (128 GiB UMA, no swap initially). This is **not** classic RAM exhaustion.

### What the logs show

- **No kernel OOM** on freeze boots (`Out of memory` / `invoked oom-killer` absent).
- **`MemAvailable` can stay high (~100 GiB)** while the machine locks up.
- Leading kernel signature (within seconds of GPU workload start):

  ```text
  amdgpu: amdgpu_amdkfd_restore_userptr_worker: Failed to resume KFD
  workqueue: svm_range_restore_work [amdgpu] hogged CPU for >10000us …
  amdgpu: Freeing queue vital buffer …, queue evicted
  ```

- Escalation path matches public gfx1151 reports: [ROCm #6165](https://github.com/ROCm/ROCm/issues/6165), [#6012](https://github.com/ROCm/ROCm/issues/6165), [#5590](https://github.com/ROCm/ROCm/issues/5590), [#5151](https://github.com/ROCm/ROCm/issues/5151), and upstream kernel patches for `svm_range_restore_work` deadlocks ([amd-gfx Feb/Oct 2025](https://lists.freedesktop.org/archives/amd-gfx/2025-February/119866.html)).

### Root cause (working theory)

Unified-memory **KFD userptr / SVM restore** stalls under sustained ROCm compute on gfx1151, often triggered when vLLM maps large model weights. Swap and `free -h` do not prevent this failure mode.

### Mitigations applied on this host

| Step | Change | Result |
|------|--------|--------|
| Swap | `/swap.img` 8 GiB + `enable-kubernetes-swap.sh` | Helps cgroup/OOM pressure; **does not fix KFD stall** |
| GRUB | `amd_iommu=off` → **`iommu=pt`** (keep `amdgpu.cwsr_enable=0`) | AMD-recommended; **KFD stall still reproduced** |
| MES firmware | Updated `gc_11_5_0_mes{1,_2}.bin.zst` from upstream `linux-firmware.git` | Blobs updated; debugfs still reports MES `0x80`; **stall still reproduced** |
| vLLM base | Rebuilt image on `kyuz0/vllm-therock-gfx1151:20260617-094558` | **Stall still reproduced** at load (~15 s after pod start) |

Firmware backup: `/var/backups/amdeai-mes-fw-*`. GRUB backup: `/etc/default/grub.bak.*`.

### Safe default

**Keep inference scaled to zero** unless running a supervised test:

```bash
bash scripts/pause-aim-inference.sh demo diffusiongemma
kubectl patch inferenceservice diffusiongemma-26b-48844644 -n demo --type=json \
  -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0},{"op":"replace","path":"/spec/predictor/maxReplicas","value":0}]'
```

---

## Safety guards (required before any resume)

```bash
# Hard gate: swap active, MemAvailable >= 80 GiB, no recent KFD/MES warnings
bash scripts/preflight-diffusiongemma-guard.sh

# Supervised resume (operators + predictor); aborts on low memory or gpu warnings
GPU_WARN_WINDOW_MIN=5 MIN_MEM_AVAIL_GIB=80 bash scripts/resume-diffusiongemma-inference.sh
```

`scripts/preflight-diffusiongemma-guard.sh` checks:

- Active swap (`MIN_SWAP_GIB`, default 8)
- `MemAvailable` ≥ `MIN_MEM_AVAIL_GIB` (default 80)
- Memory PSI below threshold
- No recent `Failed to resume KFD` / `svm_range_restore_work` / `MES failed` / `queue evicted` in **current boot** kernel log

**Always patch `minReplicas` back to `0` after a test** — KServe will recreate the predictor if left at `1`.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Bloom + AIM Engine | `kubectl get pods -n aim-system` |
| gfx1151 labels | `bash scripts/03b-gfx1151-aim-labels.sh` |
| **HF_TOKEN** | Gemma gated model — set at AIWB install (`06b-airm-workbench.sh`) |
| Disk | **≥ 95 GiB free** on `/` (weights ~50 GiB + image layers) |
| Swap | **≥ 8 GiB** — `bash scripts/enable-kubernetes-swap.sh` |
| GPU headroom | Pause other AIM inference: `bash scripts/pause-aim-inference.sh demo` |
| Kernel cmdline | `iommu=pt amdgpu.cwsr_enable=0` (see freeze section) |

```bash
export NODE_IP=$(hostname -I | awk '{print $1}')
export DOMAIN="${NODE_IP}.nip.io"
df -h /
kubectl get crd aimservices.aim.eai.amd.com
```

---

## Quick deploy (automated)

```bash
# Catalog + image build only (Workbench Deploy from UI):
CATALOG_ONLY=1 bash scripts/12-diffusiongemma-26b.sh

# Full managed deploy (script applies AIMService):
bash scripts/12-diffusiongemma-26b.sh
```

Manifests: `manifests/aim/diffusiongemma-26b/`. Image: `images/aim-gfx1151-diffusiongemma-26b/Dockerfile`.

Deploy script runs `preflight-diffusiongemma-guard.sh` before waiting for the predictor and aborts on GPU warning signatures.

---

## Step-by-step (manual)

### Step 1 — Build and push custom AIM image

```bash
REGISTRY_HOST=$(hostname -s):32000
IMAGE=${REGISTRY_HOST}/aim-gfx1151-diffusiongemma-26b:0.11-therock
docker build -t "$IMAGE" images/aim-gfx1151-diffusiongemma-26b/
docker push "$IMAGE"
```

Base image is pinned in the Dockerfile to a dated TheRock build (not `:stable`).

### Step 2 — Apply catalog CRs

```bash
export REGISTRY_HOST=$(hostname -s):32000
envsubst '${REGISTRY_HOST}' < manifests/aim/diffusiongemma-26b/aim-clustermodel.yaml | kubectl apply -f -
envsubst '${REGISTRY_HOST}' < manifests/aim/diffusiongemma-26b/aim-clusterprofile.yaml | kubectl apply -f -
kubectl apply -f manifests/aim/diffusiongemma-26b/aim-clusterservicetemplate.yaml
kubectl apply -f manifests/aim/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml
kubectl apply -f manifests/aim/diffusiongemma-26b/aim-runtimeconfig-demo.yaml
bash scripts/ensure-diffusiongemma-chattable.sh
```

If template stuck at `Progressing`:

```bash
bash scripts/fix-diffusiongemma-template-discovery.sh
```

### Step 3 — Deploy

Workbench: `https://aiwbui.${DOMAIN}/demo/models/aim-catalog` → **google-diffusiongemma-26b** → Deploy.

Or:

```bash
kubectl apply -f manifests/aim/diffusiongemma-26b/aim-service.yaml
```

### Step 4 — Post-deploy fixes (required on gfx1151)

```bash
bash scripts/ensure-diffusiongemma-profile-mount.sh demo
bash scripts/fix-aim-httproute-gateway.sh demo
bash scripts/ensure-diffusiongemma-chattable.sh
```

### Step 5 — Validate inference (supervised only)

```bash
bash scripts/preflight-diffusiongemma-guard.sh
GPU_WARN_WINDOW_MIN=5 bash scripts/resume-diffusiongemma-inference.sh
# After test: scale back to 0 (see Safe default above)
```

---

## Engine profile notes

DiffusionGemma-specific vLLM flags (in `aim-clusterprofile.yaml`):

| Flag | Value | Why |
|------|-------|-----|
| `attention-backend` | **`TRITON_ATTN`** | `ROCM_ATTN` fails on gfx1151 (`head_size not supported`) for this model |
| `max-model-len` | `8192` | Practical single-GPU limit on 128 GiB unified memory |
| `enable-chunked-prefill` | `true` | Required for diffusion serving |
| `enforce-eager` | *(omitted)* | Incompatible with chunked prefill |
| `hf-overrides` | entropy_bound sampler | Diffusion denoising |
| `diffusion-config` | `canvas_length: 256` | Block diffusion canvas |

vLLM base must be **0.22+** (`--diffusion-config`); image uses `kyuz0/vllm-therock-gfx1151:20260617-094558`.

---

## Performance testing

Same metrics as `tests/perf/test_qwen_moe_perf.py`:

- TTFT (streaming, short prompt)
- Sustained throughput (5×50 tokens)
- Latency distribution (short / medium / long, P50/P95)
- Concurrent requests (4 threads)

### Harness (ready; blocked on stable inference)

```bash
# After predictor is Running and guard passes:
bash scripts/run-diffusiongemma-perf.sh

# Or manually:
PERF_ENDPOINT=https://${NODE_IP}/demo/<httproute-uuid> \
PERF_MODEL=google/diffusiongemma-26B-A4B-it \
  pytest tests/perf/test_diffusiongemma_perf.py -v -s

python3 scripts/bench-vllm-endpoint.py "$PERF_ENDPOINT" "$PERF_MODEL" --json-out /tmp/dg.json
python3 scripts/compare-model-perf.py /tmp/dg.json --label "DiffusionGemma 26B"
```

Reference baselines (other models on this cluster): `tests/perf/baselines/gfx1151-r9700.json`.

### Results on this cluster (2026-06-21)

**No DiffusionGemma numbers obtained.** Each supervised load attempt tripped `Failed to resume KFD` within ~15 s and was aborted before `/v1/chat/completions` succeeded.

Reference numbers for comparison (prior agent runs on gfx1151):

| Model | TTFT (median) | Throughput (median) | Source |
|-------|---------------|---------------------|--------|
| Qwen3.6-27B (no MTP) | 0.40 s | 4.23 tok/s | Agent benchmark, max_tokens=128 |
| Qwen3.6-27B (MTP warm) | 0.67 s | 7.29 tok/s | Agent benchmark, max_tokens=128 |
| Qwen3.6-35B MoE | — | ≥8 tok/s threshold | `test_qwen_moe_perf.py` (no recorded run) |
| **DiffusionGemma 26B** | **blocked** | **blocked** | KFD stall at GPU load |

---

## E2E testing (AI Workbench)

| Test | Command | When |
|------|---------|------|
| Catalog + Deploy dialog | `E2E_STACK=1 E2E_AIWB=1 E2E_DIFFUSIONGEMMA=1 pytest tests/e2e/test_aiwb_ui.py -k diffusiongemma -v` | After catalog prep |
| Full Deploy confirm | `E2E_DIFFUSIONGEMMA_DEPLOY=1 pytest …::test_diffusiongemma_deploy_confirm_full -v -s` | Manual; weights already downloaded |
| Chat | `E2E_AIWB=1 E2E_DIFFUSIONGEMMA=1 pytest …::test_diffusiongemma_chat -v` | After Running + chattable |

```bash
E2E_DIFFUSIONGEMMA=1 bash scripts/run-e2e-stack-validation.sh
```

---

## Troubleshooting

### Template stuck at Progressing

```bash
bash scripts/fix-diffusiongemma-template-discovery.sh
```

### Freeze / KFD stall during load

1. Scale inference to zero immediately.
2. Check kernel log: `journalctl -k -b | rg -i 'Failed to resume KFD|svm_range_restore|MES failed'`
3. Do **not** rely on `free -h` alone — memory can look healthy.
4. Next platform steps (when AMD ships fixes): kernel ≥6.19 with gfx1151 VGPR SRU, newer MES/PMFW firmware, TheRock develop nightlies.

### Pause / resume

```bash
bash scripts/pause-aim-inference.sh demo diffusiongemma
bash scripts/preflight-diffusiongemma-guard.sh
GPU_WARN_WINDOW_MIN=5 bash scripts/resume-diffusiongemma-inference.sh
```

---

## Teardown (deployment only — keeps catalog)

```bash
kubectl delete aimservice diffusiongemma-26b -n demo --ignore-not-found
kubectl patch inferenceservice diffusiongemma-26b-48844644 -n demo --type=json \
  -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0}]'
```

---

## Related docs

- [QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md)
- [AIM_CATALOG_MODEL_DEPLOY_GFX1151.md](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md)
- [AMD Strix Halo optimization](https://rocm.docs.amd.com/en/latest/how-to/system-optimization/strixhalo.html)
- [Google DiffusionGemma developer guide](https://developers.googleblog.com/diffusiongemma-the-developer-guide/)
- [vLLM DiffusionGemma blog](https://vllm.ai/blog/2026-06-10-diffusion-gemma)
