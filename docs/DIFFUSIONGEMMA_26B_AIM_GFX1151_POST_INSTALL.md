# DiffusionGemma 26B managed AIMService on gfx1151 — post-Bloom install guide

**Audience:** Host with a working Cluster Bloom installation ([BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md)).

> **Generic catalog playbook:** [AIM_CATALOG_MODEL_DEPLOY_GFX1151.md](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md). This document is the **DiffusionGemma-specific** deep dive.

**Goal:** Deploy `google/diffusiongemma-26B-A4B-it` as a managed `AIMService` on gfx1151 (Radeon 8060S / R9700). DiffusionGemma is a discrete diffusion LLM (dLLM) on the Gemma 4 MoE backbone — vLLM serves it with block-diffusion denoising, not standard autoregressive decoding.

**Pattern:** Same custom AIM image strategy as Qwen ([QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md)): `aim-runtime` from `aim-base:0.11` layered onto `kyuz0/vllm-therock-gfx1151:latest` (vLLM 0.22+ with `--diffusion-config`). Do **not** use `:stable` for DiffusionGemma — it is vLLM 0.19.x and has no `--diffusion-config`.

---

## Status on this cluster (2026-06-21)

| Item | State |
|------|-------|
| Catalog CRs | Applied |
| Weights (`AIMArtifact`) | Downloaded (~48 GiB PVC) |
| Custom AIM image | `{hostname}:32000/aim-gfx1151-diffusiongemma-26b:0.11-therock` on `kyuz0/vllm-therock-gfx1151:latest` |
| Inference (predictor) | **Working** with tuned profile below |
| Performance (extended, Qwen-aligned prompts + warmup) | TTFT **1.05 s**, long-output **46.7 tok/s** per-request, 4/4 concurrent |

> **Throughput note:** the short-output throughput test (5×50 tok) reports only ~8.7 tok/s, but that is a *measurement artifact* — DiffusionGemma denoises a fixed 256-token canvas per block regardless of requested length, so tiny outputs pay nearly the full per-canvas cost. The real generation speed measured with 256-token outputs is **~46 tok/s**. Always judge dLLM throughput with canvas-sized (≥256 tok) generations.

---

## What was needed to get this running

Three separate problems were misdiagnosed as a single “gfx1151 KFD freeze”. Qwen 3.6 vLLM already works on the same KFD path; host-side Gemma 4 “AIM” uses `llama.cpp` and never hits this vLLM path.

| # | Problem | Symptom | Fix |
|---|---------|---------|-----|
| 1 | **vLLM startup OOM** | `CrashLoopBackOff`; log: `Free memory on device … less than desired GPU memory utilization (0.85, 108.8 GiB)` | Set `gpu-memory-utilization: 0.60` in profile |
| 2 | **HIP graph capture on gfx1151** | SVM/userptr warnings during load; heavy memory churn | Set `enforce-eager: true` (same as Qwen gfx1151 profile) |
| 3 | **Benign KFD log lines** | `Failed to resume KFD` during weight load looked fatal | Allow load to complete (~6 min); mem may dip to ~18 GiB available while mapping ~50 GiB weights |
| 4 | **Missing container env** | vLLM v1 engine path; allocator defaults | Patch InferenceService pod env: `HSA_XNACK=0`, `PYTORCH_HIP_ALLOC_CONF=expandable_segments:False`, `VLLM_USE_V1=0` |
| 5 | **Wrong vLLM base** | `:stable` has no diffusion support | Rebuild image on `kyuz0/vllm-therock-gfx1151:latest` |

**Do not** put `VLLM_USE_V1` in the profile ConfigMap `env_vars` — aim-runtime validation rejects it. Inject it on the InferenceService container env instead.

---

## Winning profile (gfx1151)

Applied in [`manifests/aim/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml`](../manifests/aim/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml):

| Setting | Value | Why |
|---------|-------|-----|
| `gpu-memory-utilization` | **0.60** | 0.85 required 108.8 GiB; ~97 GiB free at startup with desktop/k8s |
| `enforce-eager` | **true** | Matches Qwen gfx1151; disables HIP/CUDAGraph capture |
| `attention-backend` | `TRITON_ATTN` | `ROCM_ATTN` fails (`head_size not supported`) for this model |
| `enable-chunked-prefill` | `true` | Required for diffusion serving |
| `max-model-len` | `8192` | Practical limit on 128 GiB UMA |
| `diffusion-config` | `{"canvas_length": 256}` | Block diffusion canvas (leave at 256; training-tied) |
| `diffusion_entropy_bound` | **0.15** | Tuned 2026-06-21: best TPS/TTFT of {0.10, 0.15, 0.20} on gfx1151. Higher commits tokens in fewer denoise passes; 0.20 regressed |
| Container env (ISVC patch) | `HSA_XNACK=0`, `PYTORCH_HIP_ALLOC_CONF=expandable_segments:False`, `VLLM_USE_V1=0` | Reduce SVM churn; note v0.22+ may ignore `VLLM_USE_V1` |

---

## Prerequisites

```bash
export NODE_IP=$(hostname -I | awk '{print $1}')
export DOMAIN="${NODE_IP}.nip.io"
export REGISTRY_HOST=$(hostname -s):32000
export NS=demo

kubectl get nodes
kubectl get pods -n aim-system
kubectl get pods -n aiwb
kubectl get crd aimservices.aim.eai.amd.com
df -h /

# Swap (≥ 8 GiB recommended on 128 GiB UMA with no default swap)
swapon --show
# If empty: sudo fallocate -l 8G /swap.img && sudo chmod 600 /swap.img && sudo mkswap /swap.img && sudo swapon /swap.img

# Memory headroom before load (aim for ≥ 80 GiB available)
LANG=C free -g

# Pause other AIM inference on the GPU
kubectl get inferenceservice -n "${NS}" -o wide
for isvc in $(kubectl get inferenceservice -n "${NS}" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -vi diffusiongemma || true); do
  kubectl patch inferenceservice "${isvc}" -n "${NS}" --type=json \
    -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0},{"op":"replace","path":"/spec/predictor/maxReplicas","value":0}]'
done
```

| Requirement | Notes |
|-------------|-------|
| Bloom + AIM Engine | `kubectl get pods -n aim-system` all Ready |
| **HF_TOKEN** | Gemma gated model — configured at AIWB install |
| Disk | **≥ 95 GiB free** on `/` (weights ~50 GiB + image) |
| Swap | **≥ 8 GiB** active |
| Kernel cmdline | `iommu=pt amdgpu.cwsr_enable=0` (see host GRUB) |

---

## Step-by-step cluster bring-up

### Step 1 — Build and push the custom AIM image

On the cluster node (requires Docker and local registry at `:32000`):

```bash
# From the amdeai repo root on the cluster node

IMAGE="${REGISTRY_HOST}/aim-gfx1151-diffusiongemma-26b:0.11-therock"
docker build -t "${IMAGE}" images/aim-gfx1151-diffusiongemma-26b/
docker push "${IMAGE}"
```

Base image in Dockerfile: `kyuz0/vllm-therock-gfx1151:latest` (vLLM 0.22+ with `--diffusion-config`).

Verify diffusion support in the base (optional):

```bash
docker run --rm kyuz0/vllm-therock-gfx1151:latest \
  python -m vllm.entrypoints.openai.api_server --help 2>&1 | grep diffusion-config
```

---

### Step 2 — Apply catalog and profile manifests

```bash
# From the amdeai repo root

envsubst '${REGISTRY_HOST}' < manifests/aim/diffusiongemma-26b/aim-clustermodel.yaml | kubectl apply -f -
envsubst '${REGISTRY_HOST}' < manifests/aim/diffusiongemma-26b/aim-clusterprofile.yaml | kubectl apply -f -
kubectl apply -f manifests/aim/diffusiongemma-26b/aim-clusterservicetemplate.yaml
kubectl apply -f manifests/aim/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml
kubectl apply -f manifests/aim/diffusiongemma-26b/aim-runtimeconfig-demo.yaml

kubectl get aimclustermodel google-diffusiongemma-26b
kubectl get aimclusterprofile diffusiongemma-26b-r9700-gfx1151-latency
kubectl get configmap diffusiongemma-26b-r9700-gfx1151-latency-profile -n "${NS}"
```

Ensure the cluster model exposes chat tags for Workbench:

```bash
kubectl patch aimclustermodel google-diffusiongemma-26b --type=merge \
  -p='{"spec":{"discovery":{"extractMetadata":true}}}'
kubectl get aimclustermodel google-diffusiongemma-26b \
  -o jsonpath='{.status.imageMetadata.model.tags}{"\n"}'
# Expect: text-generation chat instruction diffusion
```

If the service template stays `Progressing`, check the operator job:

```bash
kubectl get aimclusterservicetemplate diffusiongemma-26b-r9700-gfx1151-latency -o yaml
kubectl get jobs -n aim-system | grep -i diffusion
kubectl logs -n aim-system -l job-name --tail=50
```

---

### Step 3 — Deploy the AIMService

**Option A — AI Workbench:** `https://aiwbui.${DOMAIN}/demo/models/aim-catalog` → **google-diffusiongemma-26b** → Deploy → Confirm.

**Option B — kubectl:**

```bash
kubectl apply -f manifests/aim/diffusiongemma-26b/aim-service.yaml

kubectl get aimservice diffusiongemma-26b -n "${NS}" -w
kubectl get aimartifact -n "${NS}" | grep -i diffusion
kubectl wait --for=condition=Ready aimartifact --all -n "${NS}" --timeout=5400s
```

Wait until weights are on the PVC (`AIMArtifact` / download job Succeeded).

---

### Step 4 — Mount the tuned profile ConfigMap on the InferenceService

Discover the InferenceService name (Workbench deploys a hashed name):

```bash
ISVC=$(kubectl get inferenceservice -n "${NS}" -o name | grep -i diffusiongemma | head -1 | cut -d/ -f2)
echo "InferenceService: ${ISVC}"
```

Re-apply the profile ConfigMap (idempotent), then patch the predictor to mount it and inject allocator env vars.

> **Note:** The merge patch below sets the profile volume and three env vars on `kserve-container`. If your ISVC already has extra volumes or env entries, export the current spec first (`kubectl get inferenceservice "${ISVC}" -n "${NS}" -o yaml`) and merge those fields before applying.

```bash
kubectl apply -f manifests/aim/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml

kubectl patch inferenceservice "${ISVC}" -n "${NS}" --type=merge -p "$(cat <<'EOF'
{
  "spec": {
    "predictor": {
      "volumes": [
        {
          "name": "diffusiongemma-26b-profile",
          "configMap": {
            "name": "diffusiongemma-26b-r9700-gfx1151-latency-profile"
          }
        }
      ],
      "containers": [
        {
          "name": "kserve-container",
          "volumeMounts": [
            {
              "name": "diffusiongemma-26b-profile",
              "mountPath": "/workspace/aim-runtime/profiles/google/diffusiongemma-26b",
              "readOnly": true
            }
          ],
          "env": [
            {"name": "VLLM_USE_V1", "value": "0"},
            {"name": "HSA_XNACK", "value": "0"},
            {"name": "PYTORCH_HIP_ALLOC_CONF", "value": "expandable_segments:False"}
          ]
        }
      ]
    }
  }
}
EOF
)"
```

Restart the predictor so it picks up the profile and env:

```bash
kubectl delete pod -n "${NS}" -l "serving.kserve.io/inferenceservice=${ISVC}" --force --grace-period=0
```

Verify the pod will use the tuned profile (after it starts):

```bash
POD=$(kubectl get pods -n "${NS}" -l component=predictor --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n "${NS}" "${POD}" | grep -E 'gpu-memory-utilization|enforce-eager|tensor-parallel'
# Expect: --gpu-memory-utilization 0.6 ... --enforce-eager ... --diffusion-config
kubectl exec -n "${NS}" "${POD}" -- env | grep -E 'HSA_XNACK|PYTORCH_HIP_ALLOC|VLLM_USE_V1'
```

---

### Step 5 — Scale up inference (supervised first load)

Before scaling up, confirm memory and kernel log are clean enough to start:

```bash
LANG=C free -g    # aim for ≥ 80 GiB in "available" column before load
swapon --show
journalctl -k -b --since "30 minutes ago" --no-pager | rg -i 'hogged CPU|queue evicted' | tail -5 || true
```

Scale the predictor to 1 replica:

```bash
kubectl patch inferenceservice "${ISVC}" -n "${NS}" --type=json \
  -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":1},{"op":"replace","path":"/spec/predictor/maxReplicas","value":1}]'
```

**First load takes ~5–6 minutes.** During weight mapping, `MemAvailable` may drop to ~18 GiB — this is expected on 128 GiB UMA. You may see benign kernel lines:

```text
amdgpu: amdgpu_amdkfd_restore_userptr_worker: Failed to resume KFD
```

These alone do **not** mean failure if the pod eventually becomes Ready. Watch progress:

```bash
watch -n10 'kubectl get inferenceservice '"${ISVC}"' -n '"${NS}"'; LANG=C free -g | awk "/^Mem:/{print \"avail GiB:\", \$7}"; kubectl get pods -n '"${NS}"' -l component=predictor'
```

Wait for Ready:

```bash
kubectl wait --for=condition=Ready pod -n "${NS}" -l component=predictor --timeout=1800s
kubectl get inferenceservice "${ISVC}" -n "${NS}" -o jsonpath='{.status.conditions[?(@type=="PredictorReady")].status}{"\n"}'
```

If the pod crashes with OOM in logs, lower `gpu-memory-utilization` further (e.g. `0.55`) in the ConfigMap, re-apply Step 4, and retry.

---

### Step 6 — Verify inference

**In-cluster (from a debug pod or the predictor itself):**

```bash
POD=$(kubectl get pods -n "${NS}" -l component=predictor --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n "${NS}" "${POD}" -- curl -sf http://localhost:8000/health
kubectl exec -n "${NS}" "${POD}" -- curl -sf http://localhost:8000/v1/models

kubectl exec -n "${NS}" "${POD}" -- curl -sf http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"google/diffusiongemma-26B-A4B-it","messages":[{"role":"user","content":"Reply with exactly: ready"}],"max_tokens":20,"temperature":0}'
```

**Via port-forward from the host:**

```bash
kubectl port-forward -n "${NS}" "${POD}" 18080:8000 &
curl -sf http://127.0.0.1:18080/health
curl -sf http://127.0.0.1:18080/v1/models | python3 -m json.tool | head -20
kill %1
```

**Via HTTPRoute (if gateway routing works):**

```bash
kubectl get httproute -n "${NS}" | grep -i diffusion
ROUTE_PATH=$(kubectl get httproute -n "${NS}" -o jsonpath='{.items[?(@.metadata.name contains "diffusion")].spec.rules[0].matches[0].path.value}' 2>/dev/null | head -1)
curl -sk "https://${NODE_IP}${ROUTE_PATH}/health"
```

---

### Step 7 — Performance benchmark (Qwen-aligned prompts)

Uses the same prompts as [`tests/perf/test_qwen_moe_perf.py`](../tests/perf/test_qwen_moe_perf.py):

| Test | Prompt |
|------|--------|
| Warmup / throughput | *Write a short technical description of mixture-of-experts architecture.* |
| TTFT | *Reply with exactly: ready* |
| Concurrent | *Name one advantage of MoE over dense models in one sentence.* |
| Latency sizes | short (32→30 tok), medium (256→60), long (1024→80) via repeated `"silicon "` filler |

**Extended results on this cluster (2026-06-21, entropy_bound=0.15, after multi-shape warmup):**

| Metric | DiffusionGemma | Qwen3.6-27B ref | Qwen3.6-35B MoE threshold |
|--------|----------------|-----------------|---------------------------|
| TTFT (3 runs, median) | **1.05 s** | 0.40 s | ≤ 10 s ✓ |
| Throughput (long, 256 tok/req) | **46.7 tok/s** per-request | — | — |
| Throughput (short 5×50 tok) | 8.7 tok/s *(artifact, see note)* | 4.23 tok/s | ≥ 8.0 ✓ |
| Latency P95 | **3.25 s** | — | ≤ 120 s ✓ |
| Concurrent | **4/4** | — | — |

Cold TTFT (no warmup) was ~9.6 s; the benchmark now does a multi-shape warmup (short/medium/long + canvas-sized output) so Triton kernels (`kernel_unified_attention`, `fused_moe_kernel`) JIT off-clock instead of spiking the first scored requests.

**Tuning sweep (2026-06-21).** All variants are within a ~42–48 tok/s band; TTFT is structurally ~1.0 s (prefill + one canvas denoise) and barely moves:

| Config | TTFT (s) | Long TPS (tok/s) | Verdict |
|--------|----------|------------------|---------|
| entropy 0.10, 48 steps, eager (prior) | 1.07 | 45.7 | baseline |
| **entropy 0.15** | **1.04** | **48.1** | **adopted** |
| entropy 0.20 | 1.04 | 45.4 | regressed |
| entropy 0.15 + `max_denoising_steps`=32 | 1.04 | 43.3 | no gain (adaptive stop already < 48) |
| entropy 0.15 + `enforce-eager: false` (torch.compile + CUDA graphs) | 1.28 | 42.3 | **worse** — keep eager on gfx1151 |
| entropy 0.15 + AITER MoE (`VLLM_ROCM_USE_AITER[_MOE]=1`) | 1.04 | 46.3 | neutral — kept off for stability |

Example manual TTFT + throughput via port-forward:

```bash
kubectl port-forward -n "${NS}" "${POD}" 18080:8000 &

# Warmup (discarded)
curl -sf http://127.0.0.1:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"google/diffusiongemma-26B-A4B-it","messages":[{"role":"user","content":"Write a short technical description of mixture-of-experts architecture."}],"max_tokens":50,"temperature":0}' \
  -o /dev/null

# TTFT-style short prompt
curl -sf http://127.0.0.1:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"google/diffusiongemma-26B-A4B-it","messages":[{"role":"user","content":"Reply with exactly: ready"}],"max_tokens":20,"temperature":0,"stream":true}'

kill %1
```

After the run, check memory and logs:

```bash
LANG=C free -h
journalctl -k -b --since "30 minutes ago" --no-pager | rg -i 'Failed to resume KFD|hogged CPU|queue evicted|OOM' | tail -20
kubectl logs -n "${NS}" "${POD}" --tail=100 | rg -i 'ERROR|Traceback|ValueError|OOM' || echo "No errors in predictor tail"
```

---

### Step 8 — Pause inference when idle

DiffusionGemma holds ~100 GiB of unified memory while running. Scale to zero when not in use:

```bash
kubectl patch inferenceservice "${ISVC}" -n "${NS}" --type=json \
  -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0},{"op":"replace","path":"/spec/predictor/maxReplicas","value":0}]'

kubectl get pods -n "${NS}" -l component=predictor
LANG=C free -g
```

---

## Engine profile reference

Full profile YAML: [`manifests/aim/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml`](../manifests/aim/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml)

vLLM command line the aim-runtime generates (check predictor logs):

```text
python -m vllm.entrypoints.openai.api_server \
  --model /workspace/cache/google/diffusiongemma-26B-A4B-it \
  --tensor-parallel-size 1 \
  --gpu-memory-utilization 0.6 \
  --max-model-len 8192 \
  --max-num-seqs 4 \
  --attention-backend TRITON_ATTN \
  --enforce-eager \
  --trust-remote-code \
  --enable-chunked-prefill \
  --generation-config vllm \
  --hf-overrides '{"diffusion_sampler": "entropy_bound", "diffusion_entropy_bound": 0.15}' \
  --diffusion-config '{"canvas_length": 256}' \
  --port 8000
```

---

## Troubleshooting

### Predictor CrashLoopBackOff — GPU memory OOM at startup

```bash
kubectl logs -n "${NS}" "${POD}" --previous | rg -i 'Free memory on device|gpu-memory-utilization'
```

Fix: set `gpu-memory-utilization: 0.60` (or lower) in the profile ConfigMap, re-apply Step 4.

### Profile not applied — still shows 0.85 or no enforce-eager

```bash
kubectl get inferenceservice "${ISVC}" -n "${NS}" -o yaml | rg -A5 'volumeMounts|diffusiongemma-26b-profile'
kubectl logs -n "${NS}" "${POD}" | grep 'Execution Command' -A1
```

Fix: repeat Step 4 (mount + env patch + pod delete).

### `Failed to resume KFD` during load

Usually **benign** if the pod eventually reaches Ready. Abort only if you also see sustained `hogged CPU` bursts, `queue evicted`, or the pod never becomes Ready within ~30 min:

```bash
journalctl -k -b -f | rg -i 'Failed to resume KFD|hogged CPU|queue evicted'
kubectl describe pod -n "${NS}" "${POD}"
```

### Gateway / HTTPRoute connection reset

Use port-forward to the predictor (Step 6) until HTTPRoute is fixed:

```bash
kubectl get httproute -n "${NS}" -o yaml
kubectl get gateway -n envoy-gateway-system
```

### Template stuck at Progressing

```bash
kubectl describe aimclusterservicetemplate diffusiongemma-26b-r9700-gfx1151-latency
kubectl get jobs -n aim-system
kubectl logs -n aim-system -l job-name --tail=100
```

---

## Teardown (deployment only — keeps catalog)

```bash
kubectl delete aimservice diffusiongemma-26b -n "${NS}" --ignore-not-found
kubectl patch inferenceservice "${ISVC}" -n "${NS}" --type=json \
  -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0},{"op":"replace","path":"/spec/predictor/maxReplicas","value":0}]'
```

To remove weight PVCs as well (frees ~48 GiB disk):

```bash
kubectl get pvc -n "${NS}" | grep -i diffusion
# kubectl delete pvc <name> -n "${NS}"   # only when sure
```

---

## Historical note: early freeze investigation

Initial attempts triggered full desktop freezes when swap was absent, Keycloak OOM'd, and multiple large workloads started together. After adding 8 GiB swap, staging cluster startup, and the profile fixes above, DiffusionGemma loads and runs without freezing. Host-level changes tried earlier (IOMMU `iommu=pt`, MES firmware update) did not by themselves fix the vLLM OOM misconfiguration.

Kernel signatures seen during **misconfigured** loads (not necessarily fatal once profile is correct):

```text
amdgpu: amdgpu_amdkfd_restore_userptr_worker: Failed to resume KFD
workqueue: svm_range_restore_work [amdgpu] hogged CPU for >10000us …
amdgpu: Freeing queue vital buffer …, queue evicted
```

---

## Related docs

- [QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md)
- [AIM_CATALOG_MODEL_DEPLOY_GFX1151.md](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md)
- [AMD Strix Halo optimization](https://rocm.docs.amd.com/en/latest/how-to/system-optimization/strixhalo.html)
- [Google DiffusionGemma developer guide](https://developers.googleblog.com/diffusiongemma-the-developer-guide/)
- [vLLM DiffusionGemma blog](https://vllm.ai/blog/2026-06-10-diffusion-gemma)
