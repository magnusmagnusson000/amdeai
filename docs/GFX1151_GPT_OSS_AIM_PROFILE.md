# gfx1151 — gpt-oss-20b AIM in-cluster deployment analysis

**Platform:** Asus Z13 · Radeon 8060S (gfx1151) · 128 GB LPDDR5x · ROCm 7.2.3  
**Validated:** 2026-06-10 against live cluster (`demo/wb-aim-e21dff22`)  
**Image:** `amdenterpriseai/aim-openai-gpt-oss-20b:0.11.0`

This document records why the AI Workbench **gpt-oss-20b** `AIMService` crash-loops on gfx1151, what must change in the AIM profile/template layer, and why disabling AITER alone is not sufficient.

**Related docs:**

- [AIM_ENGINE_DEEP_DIVE.md](AIM_ENGINE_DEEP_DIVE.md) — AIM reconciliation, templates vs profiles
- [call-flows/03b-gfx1151-aim-labels.md](call-flows/03b-gfx1151-aim-labels.md) — R9700 accelerator label mapping
- [gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md) — host llama.cpp HIP path (recommended for Gemma/SLMs)

---

## Executive summary

| Layer | Status on gfx1151 |
|-------|-------------------|
| Model download (`AIMArtifact`) | Works — ~41 GB HF cache completed |
| AIM template selection (Kubernetes) | Works — MI300X fp4 latency template marked `Ready` |
| AIM runtime profile selection (container) | **Fails** — `Detected GPU: None`, 0 compatible profiles |
| vLLM startup with MI300X fp4 + AITER | **Not viable** on RDNA3.5 without a custom gfx1151 profile |

**Bottom line:** The pod dies in **aim-runtime profile auto-selection** before vLLM starts. Fixing that requires injecting `AIM_PROFILE_ID` (or a `customProfile` template). Running correctly on gfx1151 additionally requires an **R9700-targeted custom profile** with **AITER disabled** and Radeon attention fallbacks — and may still hit **MXFP4 MoE** limitations in vLLM 0.16.0 (bundled in the 0.11.0 AIM image).

The validated gfx1151 path in this repo remains **host llama.cpp HIP** or **AIMModel external endpoint** registration, not managed in-cluster vLLM for gpt-oss fp4.

---

## Observed failure

### Pods (namespace `demo`)

| Pod | Status | Notes |
|-----|--------|-------|
| `hf---openai-gpt-oss-20b-...-download-...` | Completed | Weights cached to PVC |
| `wb-aim-e21dff22-518bd75e-predictor-...` | CrashLoopBackOff | Exit code 1, ~11 s lifetime |

### AIMService

```text
demo/wb-aim-e21dff22
  model:   amdenterpriseai-aim-openai-gpt-oss-20b-0-11-0-51bf41
  template: amdenterpriseai-aim-openai-gpt-oss-20b-0-1x-mi300x-lat-fp4-fdd1
  status:  Starting (never reaches Running)
```

### Container log (fatal)

```text
Assessing 80 profiles with config:
  Engine: vllm
  Precision: fp4
  Detected GPU: None
  GPU Count: 0
  Metric: latency
Found 0 compatible profiles
ERROR: No compatible profile found for AIM openai/gpt-oss-20b.
        Profile breakdown: 40 gpu_mismatch, 40 metric_mismatch
```

Readiness probe fails (`connection refused` on `:8000`) because the AIM runtime exits before exec'ing vLLM.

---

## Root cause analysis

Two independent problems stack on top of each other.

### Problem 1 — Profile auto-selection (immediate crash)

The AIM container entrypoint (`aim-runtime`) selects a vLLM profile YAML under `/workspace/aim-runtime/profiles/` using:

- `AIM_METRIC`, `AIM_PRECISION` (set on the pod)
- Live GPU detection inside the container
- Embedded profile metadata (`metadata.gpu`, `metadata.gpu_count`, …)

**What the InferenceService actually injects:**

| Variable | Value on pod |
|----------|--------------|
| `AIM_METRIC` | `latency` |
| `AIM_PRECISION` | `fp4` |
| `AIM_PROFILE_ID` | **missing** |
| `AIM_GPU_MODEL` / `AIM_GPU_COUNT` | **missing** |
| Profile `env_vars` (AITER, etc.) | **missing** |

The cluster template **does** hold a discovered profile in `status.profile` (from the discovery job dry-run), but AIM Engine v1alpha1 **does not propagate** `status.profile.env_vars` or `status.profile.engine_args` into the InferenceService container unless:

- `spec.profileId` is set on the template (becomes `AIM_PROFILE_ID`), or
- `spec.customProfile` is set (ConfigMap mount + `AIM_PROFILE_ID=custom/...`).

The gpt-oss-20b image metadata lists MI300X deployments **without** `profileId` for several entries. Auto-generated `AIMClusterServiceTemplate` resources therefore have empty `spec.profileId` even though discovery populated `status.profile`.

**Result:** Runtime falls back to scanning all 80 embedded MI-series profiles; gfx1151 is not detected as MI300X → `gpu_mismatch` on every latency profile and `metric_mismatch` on every throughput profile.

### Problem 2 — Wrong stack for gfx1151 (post-selection)

Even if profile selection were fixed to `vllm-mi300x-mxfp4-tp1-latency`, that profile targets **CDNA MI300X** with:

```yaml
env_vars:
  VLLM_ROCM_USE_AITER: "1"
  VLLM_ROCM_USE_AITER_MHA: "0"
  VLLM_ROCM_USE_AITER_UNIFIED_ATTENTION: "1"
  VLLM_ROCM_QUICK_REDUCE_QUANTIZATION: INT4
```

On gfx1151 (RDNA 3.5):

- **AITER** assembly kernels are CDNA-oriented; many ops still have `TODO: Add NAVI support` in upstream aiter.
- AMD vLLM docs recommend **`ROCM_ATTN`** / Triton fallbacks for **Radeon / fallback** — backends that do not require `VLLM_ROCM_USE_AITER=1`.
- **HIP graph capture** (vLLM V1) is a known failure mode on gfx1151; `enforce-eager` may be required.

Additionally, Bloom labels the node as `MI300X` (`amd.com/gpu.device-id=74a1`) for Cluster Forge compatibility while the actual device is gfx1151 (`amdeai.com/gpu.device-id.actual=1586`). Template GPU health checks pass; container GPU identity does not match MI300X profile metadata.

---

## Image inspection (`aim-openai-gpt-oss-20b:0.11.0`)

Pulled and inspected 2026-06-10:

| Property | Value |
|----------|-------|
| Base | `ghcr.io/silogen/aim-base:0.11` |
| vLLM | **0.16.0** |
| Baked `AIM_ID` | `openai/gpt-oss-20b` |
| `AIM_ALLOW_GENERAL_PROFILE_FALLBACK` | `false` |
| Embedded profiles | MI250X / MI300X / MI325X / MI350X / MI355X **fp4 only** |
| R9700 / gfx1151 profile | **None** |

Sample profile path:

```text
/workspace/aim-runtime/profiles/openai/gpt-oss-20b/vllm-mi300x-mxfp4-tp1-latency.yaml
```

Catalog `recommendedDeployments` on `AIMClusterModel` lists MI250X–MI355X only; no W7900/R9700 entries.

**Implication:** vLLM 0.16.0 predates several gfx1151 MXFP4 MoE fixes (Triton `on_gfx1x()` gating landed in later vLLM). Even a correct custom profile may fail at MoE kernel selection until a newer AIM/vLLM stack is used.

---

## AITER on gfx1151 (context)

`VLLM_ROCM_USE_AITER=1` is the master switch for AMD's AI Tensor Engine kernels inside vLLM. The gpt-oss MI300X profile enables it with unified attention.

| Topic | gfx1151 verdict |
|-------|-----------------|
| aiter arch map (gfx1151 recognition) | Fixed upstream ([ROCm/aiter#1498](https://github.com/ROCm/aiter/pull/1498)) |
| Full AITER kernel coverage on RDNA3.5 | **Incomplete** — many CDNA-only code paths |
| AMD doc recommendation for Radeon | `ROCM_ATTN` / `TRITON_MLA` — **no AITER required** |
| gpt-oss MI300X profile default | AITER **on** — wrong for gfx1151 |

For a gfx1151 custom profile, set all `VLLM_ROCM_USE_AITER_*` to `0` and use `--attention-backend ROCM_ATTN` (or let vLLM pick Radeon fallback).

Community patched stacks (e.g. [kyuz0/amd-strix-halo-vllm-toolboxes](https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes)) selectively enable AITER attention while forcing Triton fallbacks for MoE/RMSNorm on `gfx1x`.

---

## Change tiers

### Tier 1 — Unblock profile selection (diagnostic only)

Patch `AIMService.spec.env` to bypass auto-selection and spoof the GPU the MI300X profile expects:

```yaml
spec:
  env:
    - name: AIM_PROFILE_ID
      value: vllm-mi300x-mxfp4-tp1-latency
    - name: AIM_GPU_MODEL
      value: MI300X
    - name: AIM_GPU_COUNT
      value: "1"
    - name: AIM_MODEL_ID
      value: openai/gpt-oss-20b
    - name: AIM_ID
      value: ""
    - name: HSA_OVERRIDE_GFX_VERSION
      value: "11.5.1"
    - name: HSA_ENABLE_SDMA
      value: "0"
    - name: MIOPEN_FIND_ENFORCE
      value: "1"
    - name: PYTORCH_ROCM_ARCH
      value: gfx1151
```

**Expected:** Pod passes current crash; vLLM likely fails on AITER/MXFP4/CDNA kernels or graph capture.

AIM Engine's `hack/clone-templates-for-gpu.sh` uses the same `AIM_GPU_MODEL` spoof when cloning MI300X → MI325X templates.

### Tier 2 — Proper gfx1151 profile (required for a real attempt)

#### Prerequisites

1. Apply R9700 accelerator labels:

   ```bash
   bash scripts/03b-gfx1151-aim-labels.sh
   ```

2. Ensure gfx1151 ROCm env vars reach GPU pods (see [scripts/03-gpu-plugin.sh](../scripts/03-gpu-plugin.sh)).

#### Custom `AIMClusterServiceTemplate`

Use `customProfile` so the controller mounts profile YAML and sets `AIM_PROFILE_ID=custom/openai/gpt-oss-20b/<name>`, bypassing auto-selection entirely.

```yaml
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMClusterServiceTemplate
metadata:
  name: gpt-oss-20b-r9700-gfx1151-latency
  labels:
    aim.eai.amd.com/origin: manual
    aim.eai.amd.com/platform: gfx1151
spec:
  modelName: amdenterpriseai-aim-openai-gpt-oss-20b-0-11-0-51bf41
  aimId: openai/gpt-oss-20b
  modelId: openai/gpt-oss-20b
  metric: latency
  precision: fp4
  profileId: gfx1151-gpt-oss-latency
  hardware:
    gpu:
      model: R9700
      requests: 1
  env:
    - name: AIM_GPU_MODEL
      value: R9700
    - name: AIM_GPU_COUNT
      value: "1"
    - name: HSA_OVERRIDE_GFX_VERSION
      value: "11.5.1"
    - name: HSA_ENABLE_SDMA
      value: "0"
    - name: MIOPEN_FIND_ENFORCE
      value: "1"
    - name: PYTORCH_ROCM_ARCH
      value: gfx1151
    - name: TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL
      value: "1"
  customProfile:
    engineArgs:
      tensor-parallel-size: 1
      gpu-memory-utilization: 0.95
      max-model-len: 32768
      max-num-batched-tokens: 2048
      max-num-seqs: 256
      reasoning-parser: openai_gptoss
      tool-call-parser: openai
      attention-backend: ROCM_ATTN
      enforce-eager: true
    envVars:
      VLLM_ROCM_USE_AITER: "0"
      VLLM_ROCM_USE_AITER_MHA: "0"
      VLLM_ROCM_USE_AITER_RMSNORM: "0"
      VLLM_ROCM_USE_AITER_LINEAR: "0"
      VLLM_ROCM_USE_AITER_MOE: "0"
      VLLM_ROCM_USE_AITER_UNIFIED_ATTENTION: "0"
      VLLM_DO_NOT_TRACK: "1"
      VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS: "900"
      HSA_OVERRIDE_GFX_VERSION: "11.5.1"
      HSA_ENABLE_SDMA: "0"
      MIOPEN_FIND_ENFORCE: "1"
      PYTORCH_ROCM_ARCH: gfx1151
      GPU_ARCHS: gfx1151
```

Point the service at the new template:

```yaml
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMService
metadata:
  name: wb-aim-e21dff22
  namespace: demo
spec:
  model:
    name: amdenterpriseai-aim-openai-gpt-oss-20b-0-11-0-51bf41
  template:
    name: gpt-oss-20b-r9700-gfx1151-latency
  overrides:
    hardware:
      gpu:
        model: R9700
  cacheModel: true
  replicas: 1
```

**Design notes:**

| Field | Rationale |
|-------|-----------|
| `hardware.gpu.model: R9700` | AIM Engine v0.2.4+ Radeon class; node affinity uses PCI `7551` |
| `customProfile` | Bypasses broken auto-selection; injects engine args + env |
| AITER all `0` | RDNA-safe path per AMD vLLM Radeon guidance |
| `attention-backend: ROCM_ATTN` | Explicit Radeon fallback backend |
| `enforce-eager: true` | Avoid V1 HIP graph capture hangs on gfx1151 |
| `precision: fp4` | Matches downloaded MXFP4 weights (no re-quantize) |

#### v1alpha2 alternative

Same content as `AIMClusterProfile` + `AIMService.spec.profile` instead of deprecated `AIMClusterServiceTemplate` / `spec.template`. Preferred long-term per [AIM_ENGINE_DEEP_DIVE.md](AIM_ENGINE_DEEP_DIVE.md).

### Tier 3 — MXFP4 MoE on gfx1151 (may still block)

gpt-oss-20b is an **MXFP4 MoE** model. Additional constraints:

| Issue | Notes |
|-------|-------|
| Triton MXFP4 MoE on gfx1151 | Capability gating fixes in vLLM ≥0.19 ([vllm#37826](https://github.com/vllm-project/vllm/pull/37826), [vllm#40301](https://github.com/vllm-project/vllm/issues/40301)) |
| AIM image vLLM 0.16.0 | Likely **too old** for reliable gfx1151 MoE |
| vLLM recipes | Officially list MI300X/MI325X/MI355X and **R9700 (gfx1201)** — not gfx1151 explicitly |

If Tier 2 reaches vLLM but fails with `NotImplementedError` or MoE backend errors, options include:

- TheRock gfx1151 nightlies + patched vLLM toolbox
- Wait for AMD AIM image with newer vLLM and gfx1151 gpt-oss profile
- Use host **llama.cpp** (supports gpt-oss MXFP4 on gfx1151 with G1–G3 patches) instead of in-cluster vLLM

---

## Parameter reference

### AIM runtime (container entrypoint)

| Variable | MI300X template (default) | gfx1151 custom profile |
|----------|---------------------------|-------------------------|
| `AIM_PROFILE_ID` | missing → auto-select fails | `custom/openai/gpt-oss-20b/gfx1151-gpt-oss-latency` or `vllm-mi300x-mxfp4-tp1-latency` |
| `AIM_GPU_MODEL` | missing | `R9700` (or `MI300X` for spoof-only test) |
| `AIM_GPU_COUNT` | missing | `1` |
| `AIM_ID` vs `AIM_MODEL_ID` | image bakes `AIM_ID` | set `AIM_MODEL_ID` + clear `AIM_ID` when using cached weights |

### vLLM / ROCm (engine process via `customProfile.envVars`)

| Variable | MI300X profile | gfx1151 recommendation |
|----------|----------------|--------------------------|
| `VLLM_ROCM_USE_AITER` | `1` | `0` |
| `VLLM_ROCM_USE_AITER_UNIFIED_ATTENTION` | `1` | `0` |
| `VLLM_ROCM_QUICK_REDUCE_QUANTIZATION` | `INT4` | omit or test without |
| `HSA_OVERRIDE_GFX_VERSION` | not set | `11.5.1` |
| `HSA_ENABLE_SDMA` | not set | `0` |
| `MIOPEN_FIND_ENFORCE` | not set | `1` |
| `PYTORCH_ROCM_ARCH` / `GPU_ARCHS` | not set | `gfx1151` |

### Engine args

| Arg | MI300X profile | gfx1151 recommendation |
|-----|----------------|------------------------|
| `compilation-config.cudagraph_mode` | `FULL_AND_PIECEWISE` | omit; use `enforce-eager: true` |
| `attention-backend` | (AITER unified) | `ROCM_ATTN` |
| `reasoning-parser` | `openai_gptoss` | keep |
| `tensor-parallel-size` | `1` | keep |

---

## Verification commands

```bash
# Service and pod status
kubectl get aimservice -n demo
kubectl get pods -n demo -l app.kubernetes.io/component=inference
kubectl logs -n demo -l app.kubernetes.io/component=inference --tail=50

# Confirm env injection after patch
kubectl get inferenceservice -n demo -o yaml | grep -A30 'env:'

# Template discovery profile (cluster)
kubectl get aimclusterservicetemplate \
  amdenterpriseai-aim-openai-gpt-oss-20b-0-1x-mi300x-lat-fp4-fdd1 \
  -o jsonpath='{.status.profile.env_vars}{"\n"}'

# R9700 node labels
kubectl get node -o json | jq -r '.items[0].metadata.labels | to_entries[] |
  select(.key | test("aim-accelerator|gpu.device-id|gpu.vram")) | "\(.key)=\(.value)"'

# Cache ready
kubectl get aimtemplatecache -n demo
kubectl get pvc -n demo | grep gpt-oss
```

Success criteria:

1. Pod log shows profile selected (no `No compatible profile found`).
2. vLLM process starts; `:8000` readiness passes.
3. `curl` to the InferenceService OpenAI `/v1/models` returns gpt-oss-20b.

---

## Minimum change checklist

| # | Change | Fixes |
|---|--------|-------|
| 1 | `AIM_PROFILE_ID` + `AIM_GPU_MODEL` + `AIM_GPU_COUNT` on pod | Profile selection crash |
| 2 | `customProfile` with gfx1151 env + AITER off | Wrong MI300X/CDNA stack |
| 3 | `hardware.gpu.model: R9700` + `03b-gfx1151-aim-labels.sh` | Scheduling / affinity |
| 4 | `ROCM_ATTN`, `enforce-eager: true` | AITER + graph capture |
| 5 | Newer vLLM/AIM image (if MoE fails) | MXFP4 MoE on gfx1151 |

---

## Recommended path on this machine

For production-like inference on the Z13 today:

1. **Gemma / SLMs:** Host `llama-server` + `AIMModel` external endpoint ([scripts/07-llama-cpp.sh](../scripts/07-llama-cpp.sh), [scripts/08-gemma4-31b.sh](../scripts/08-gemma4-31b.sh)).
2. **gpt-oss-20b in-cluster:** Experimental only — apply Tier 2 custom profile; expect possible vLLM 0.16.0 MoE blockers.
3. **Stop crash loop:** Delete or suspend `demo/wb-aim-e21dff22` until a gfx1151 profile manifest is applied.

---

## Upstream follow-ups

| Target | Suggested contribution |
|--------|------------------------|
| `aim-openai-gpt-oss-20b` image labels | Add R9700 `recommendedDeployments` + `profileId` |
| AIM Engine | Propagate `status.profile.env_vars` to InferenceService when `spec.profileId` empty |
| AIM Engine | Publish gfx1151/R9700 gpt-oss profile in cluster catalog |
| vLLM / AIM base | Bump vLLM for gfx1151 MXFP4 MoE (`on_gfx1x()`) |
| aiter | Complete NAVI/RDNA3.5 kernel paths or document Radeon-only flags |

---

## Revision history

| Date | Notes |
|------|-------|
| 2026-06-10 | Initial analysis from live `demo/wb-aim-e21dff22` crash loop; image inspect vLLM 0.16.0 |
