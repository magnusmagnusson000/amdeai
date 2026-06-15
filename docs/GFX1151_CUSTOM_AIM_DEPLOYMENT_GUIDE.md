# Custom AIM Deployment on gfx1151 (Strix Halo / Radeon 8060S)

> **Workbench Deploy path (managed AIMService + custom image):** use [AIM_CATALOG_MODEL_DEPLOY_GFX1151.md](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md) instead. This guide covers the **hybrid** path (AIMService weight download + plain vLLM Deployment).

**Platform:** AMD Ryzen AI MAX / Strix Halo · gfx1151 (RDNA 3.5) · 128 GB LPDDR5x  
**AIM Engine:** v0.11 · ROCm 7.x  
**Model used as example:** `microsoft/Phi-4-mini-instruct` (3.8 B, fp16, no HF token required)  
**Status:** Validated on hardware — 2026-06-11

---

## Overview

This guide walks through deploying a custom model as an AIM (AMD Inference Model) on a
`gfx1151` (Strix Halo) GPU that is **not in the AMD AIM catalog**. It covers every
`kubectl` command and YAML manifest required from scratch.

### Why gfx1151 requires a custom approach

Standard AIM catalog models (e.g. `amdenterpriseai/aim-openai-gpt-oss-20b`) use
`amdenterpriseai/aim-base:0.11` as their runtime container. That image bundles a
PyTorch build compiled for CDNA GPUs (MI300X/MI250). On gfx1151 (RDNA 3.5),
**basic GPU kernel execution segfaults** — even `torch.randn(10, device='cuda')` fails.
This means `AIMService` + standard `InferenceService` pods cannot run vLLM on this GPU.

The solution is a three-layer hybrid:

| Layer | Resource | Purpose |
|-------|----------|---------|
| 1. Catalog registration | `AIMClusterModel` + `AIMClusterProfile` | Makes the model visible in AI Workbench; defines download source |
| 2. Weight download | `AIMService` | Triggers the `AIMArtifact` download job, creating a populated PVC |
| 3. Inference serving | Plain K8s `Deployment` + `AIMModel` | Runs vLLM in `kyuz0/vllm-therock-gfx1151:stable` (gfx1151-compiled PyTorch); registers endpoint in AI Workbench |

The `AIMService` InferenceService pod will crash (expected — see above), but the
weights PVC it creates persists and is reused by the plain Deployment.

---

## Prerequisites

### Software
- Kubernetes cluster with AIM Engine operator installed
  - Verify: `kubectl get crd aimservices.aim.eai.amd.com`
- `kubectl` configured with cluster admin permissions
- Docker Hub pull access (images are public, no auth needed)
- Sufficient free disk for model weights + optional image pull (see table below)

### Disk space

Disk requirements are **model-specific**. The `kyuz0/vllm-therock-gfx1151:stable`
image (~10 GiB) only needs to be pulled once; subsequent deployments reuse the
cached image.

| Model (example) | Weight precision | Weights PVC | Recommended free disk |
|-----------------|------------------|-------------|----------------------|
| Phi-4-mini-instruct (3.8 B) | fp16 | ~8 GiB | ~15 GiB |
| Qwen/Qwen3.6-27B (27 B) | bf16 | ~56 GiB | ~60 GiB |
| General rule | — | model size × 1.1 | weights + 15 GiB reserve |

Check free space before deploying:

```bash
df -h /
```

If disk is tight, remove unused weight PVCs from prior experiments:

```bash
kubectl get pvc -n default
# kubectl delete aimservice <name> -n default  # also removes the PVC
```

### Node label — R9700 accelerator class

The AIM operator uses `feature.node.kubernetes.io/aim-accelerator.R9700=1` to
identify gfx1151 nodes. Apply this once per cluster reboot (it is not persistent):

```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

kubectl label node "$NODE" \
  feature.node.kubernetes.io/aim-accelerator.R9700=1 \
  --overwrite
```

Verify:
```bash
kubectl get node "$NODE" --show-labels | tr ',' '\n' | grep aim-accelerator
# Expected: feature.node.kubernetes.io/aim-accelerator.R9700=1
```

> **Why this label?**  
> The `AIMClusterProfile` sets `acceleratorModel: R9700`. The AIM operator resolves
> this to the NFD label above. Without it, `AIMClusterProfile.status` shows
> `NotAvailable` and no pods schedule.

### GPU device access

Confirm the AMD GPU device plugin is running and the GPU is allocatable:
```bash
kubectl get daemonset amdgpu-device-plugin-daemonset -n kube-system
kubectl describe node "$NODE" | grep -A5 "Allocatable"
# Should show:  amd.com/gpu: 1
```

---

## Step 1 — Register the model in the AIM catalog (`AIMClusterModel`)

`AIMClusterModel` (v1alpha1) is a cluster-scoped resource that registers a model in
the AI Workbench catalog. Because `microsoft/Phi-4-mini-instruct` has no official
AMD AIM image, we author it manually with `discovery.extractMetadata: false` and
`discovery.createServiceTemplates: false` to suppress auto-discovery.

Apply the following manifest:

```yaml
# aim-clustermodel.yaml
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMClusterModel
metadata:
  name: microsoft-phi-4-mini-instruct
  labels:
    aim.eai.amd.com/origin: manual
    aim.eai.amd.com/platform: gfx1151
  annotations:
    aim.eai.amd.com/source-registry: docker.io
    aim.eai.amd.com/source-repository: amdenterpriseai/aim-base
    aim.eai.amd.com/source-tag: "0.11"
spec:
  image: amdenterpriseai/aim-base:0.11
  discovery:
    extractMetadata: false
    createServiceTemplates: false
  imageMetadata:
    baseImageRef: docker.io/amdenterpriseai/aim-base:0.11
    model:
      canonicalName: microsoft/Phi-4-mini-instruct
      hfTokenRequired: false
      tags:
        - text-generation
        - chat
        - instruction
      descriptionFull: >
        Phi-4-mini-instruct (3.8B) dense SLM by Microsoft. Validated on gfx1151
        (Strix Halo / R9700) via vLLM with ROCm HIP. No HuggingFace token required.
        Runtime config: phi4-mini-r9700-gfx1151-latency (AIMClusterProfile v1alpha2).
      recommendedDeployments:
        - gpuModel: R9700
          gpuCount: 1
          precision: fp16
          metric: latency
          profileId: phi4-mini-r9700-gfx1151-latency
          description: gfx1151 latency profile — AITER disabled, ROCM_ATTN backend
```

```bash
kubectl apply -f aim-clustermodel.yaml
kubectl get aimclustermodel microsoft-phi-4-mini-instruct
# Expected: STATUS=Ready
```

> **Image tag:** Use `amdenterpriseai/aim-base:0.11` — not `0.11.0`.
> The `.0` patch variant does not exist on Docker Hub and causes `ImagePullBackOff`.

---

## Step 2 — Define the runtime configuration (`AIMClusterProfile`)

`AIMClusterProfile` (v1alpha2) is the cluster-scoped equivalent of what AMD's
discovery controller normally auto-generates from OCI image labels. It defines the
inference engine, hardware target, environment overrides, and the HuggingFace
download source for the `AIMArtifact` system.

### Key gfx1151 constraints explained

| Setting | Value | Reason |
|---------|-------|--------|
| `acceleratorModel: R9700` | — | Maps to node label `aim-accelerator.R9700` |
| `engineArgs.attention-backend: ROCM_ATTN` | — | Radeon fallback; Flash Attention is CDNA-only |
| `engineArgs.enforce-eager: "true"` | — | Prevents HIP graph capture hang on gfx1151 |
| `engineArgs.gpu-memory-utilization: "0.40"` | — | Conservative — adjust if no other GPU workloads |
| `VLLM_ROCM_USE_AITER*: "0"` | all six flags | AITER kernels are compiled for CDNA only |
| `HSA_OVERRIDE_GFX_VERSION: "11.5.1"` | — | Reports the correct gfx version to HSA/ROCm |
| `HSA_ENABLE_SDMA: "0"` | — | Prevents HIP page faults on RDNA APU memory model |
| `TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL: "1"` | — | Enables G8 AOTriton path for gfx1151 |
| `containerEnv.AIM_GPU_MODEL: R9700` | — | Without this, `aim-runtime` sees `Detected GPU: None` and exits immediately |
| `containerEnv.VLLM_USE_V1: "0"` | — | vLLM 0.16.0 V1 EngineCore silently fails on gfx1151; V0 is stable |
| `precision: fp16` | Phi-4-mini example | Match the model's weight dtype — use `bf16` for Qwen3.6-27B |
| `resources.requests.memory` | `32Gi` for Phi-4-mini | Scale up for larger models — `64Gi` for 27 B BF16 |
| `engineArgs.max-model-len` | `8192` for Phi-4-mini | Reduce for large models on gfx1151 — `32768` is practical for 27 B |

> **`containerEnv` vs `engineEnv`:**  
> `engineEnv` is a free-form `map[string]string` passed to the vLLM process.  
> `containerEnv` uses the Kubernetes `[]EnvVar` list format (`name:`/`value:` pairs)
> and is set on the pod itself. Using map syntax in `containerEnv` causes:
> `Error from server (BadRequest): unknown field "spec.containerEnv.AIM_GPU_MODEL"`.

Apply the following manifest:

```yaml
# aim-clusterprofile.yaml
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMClusterProfile
metadata:
  name: phi4-mini-r9700-gfx1151-latency
  labels:
    aim.eai.amd.com/origin: manual
    aim.eai.amd.com/platform: gfx1151
spec:
  aimId: microsoft/phi-4-mini-instruct
  modelId: microsoft/Phi-4-mini-instruct
  profileId: phi4-mini-r9700-gfx1151-latency
  engine: vllm
  metric: latency
  precision: fp16
  type: general
  primary: true

  acceleratorModel: R9700
  acceleratorType: gpu
  acceleratorCount: 1
  resources:
    requests:
      cpu: "4"
      memory: 32Gi

  image: amdenterpriseai/aim-base:0.11

  engineArgs:
    tensor-parallel-size: "1"
    gpu-memory-utilization: "0.40"
    max-model-len: "8192"
    max-num-seqs: "64"
    attention-backend: ROCM_ATTN
    enforce-eager: "true"

  engineEnv:
    HSA_OVERRIDE_GFX_VERSION: "11.5.1"
    HSA_ENABLE_SDMA: "0"
    MIOPEN_FIND_ENFORCE: "1"
    PYTORCH_ROCM_ARCH: gfx1151
    GPU_ARCHS: gfx1151
    TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL: "1"
    VLLM_ROCM_USE_AITER: "0"
    VLLM_ROCM_USE_AITER_MHA: "0"
    VLLM_ROCM_USE_AITER_RMSNORM: "0"
    VLLM_ROCM_USE_AITER_LINEAR: "0"
    VLLM_ROCM_USE_AITER_MOE: "0"
    VLLM_ROCM_USE_AITER_UNIFIED_ATTENTION: "0"
    VLLM_DO_NOT_TRACK: "1"
    VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS: "900"

  # containerEnv MUST use []EnvVar list syntax — NOT a map
  containerEnv:
    - name: AIM_GPU_MODEL
      value: R9700
    - name: AIM_GPU_COUNT
      value: "1"
    - name: HSA_OVERRIDE_GFX_VERSION
      value: "11.5.1"
    - name: HSA_ENABLE_SDMA
      value: "0"
    - name: PYTORCH_ROCM_ARCH
      value: gfx1151
    - name: VLLM_USE_V1
      value: "0"

  modelSources:
    - modelId: microsoft/Phi-4-mini-instruct
      sourceUri: hf://microsoft/Phi-4-mini-instruct
```

```bash
kubectl apply -f aim-clusterprofile.yaml

# Wait for Ready (requires the R9700 node label from Prerequisites)
kubectl get aimclusterprofile phi4-mini-r9700-gfx1151-latency -w
# Expected: STATUS=Ready (usually < 30 seconds)
```

If it shows `NotAvailable`, the R9700 node label is missing — re-apply it from the
Prerequisites section.

---

## Step 3 — Trigger the weight download (`AIMService`)

Applying an `AIMService` causes the AIM operator to:
1. Resolve the named `AIMClusterProfile`
2. Create an `AIMArtifact` download job
3. Download weights from `hf://microsoft/Phi-4-mini-instruct` (~7.5 GiB, no token)
4. Persist weights in a dedicated PVC (`caching.mode: Dedicated`)
5. Attempt to start a KServe `InferenceService` pod ← **this will crash** on gfx1151

Step 5 failing is expected and does not matter. The weights PVC outlives the pod.

```yaml
# aim-service.yaml
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMService
metadata:
  name: phi4-mini
  namespace: default
spec:
  profile:
    name: phi4-mini-r9700-gfx1151-latency
  caching:
    mode: Dedicated
  replicas: 1
```

```bash
kubectl apply -f aim-service.yaml
```

### Monitor the download

```bash
# Watch AIMArtifact progress (appears within ~30 seconds of applying AIMService)
kubectl get aimartifact -n default -w
# Wait until PROGRESS=100 % and STATUS=Ready — this takes 5–30 min depending on connection
```

You can also watch the download pod logs:

```bash
DOWNLOAD_POD=$(kubectl get pods -n default \
  --field-selector=status.phase=Running \
  -o name | grep "phi-4-mini\|phi4-mini" | head -1)
kubectl logs -n default "$DOWNLOAD_POD" -f
```

### Find the weights PVC name

Once the `AIMArtifact` shows `Ready`, record the PVC it created — you will need this
in Step 5:

```bash
kubectl get pvc -n default | grep -i "phi\|microsoft"
# Example output:
# hf---microsoft-phi-4-mini-instruct-2e07ce61bb-cache-89d7670f   Bound   ...  15Gi

# Or read it directly from the AIMArtifact resource:
kubectl get aimartifact -n default \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.persistentVolumeClaim}{"\n"}{end}'
```

> The PVC name is deterministic — it is derived from the HuggingFace repo slug and a
> content hash. It will be the same on every fresh install for the same model.

---

## Step 4 — Free the GPU for the working inference pod

The `AIMService`-managed InferenceService pod is crash-looping (expected). Scale it
down so it releases GPU resources before deploying the working pod in Step 5.

```bash
# Find and scale down the crashing ReplicaSets
kubectl get replicasets -n default | grep phi4-mini

# Scale each one to 0 (replace <rs-name> with actual names from above)
kubectl scale replicaset <rs-name> -n default --replicas=0

# Or scale by label if multiple exist:
kubectl scale replicaset -n default \
  -l "serving.kserve.io/inferenceservice=phi4-mini" --replicas=0

# Confirm no phi4 pods hold GPU resources
kubectl get pods -n default | grep phi4
# Should show only Completed (download pod) or nothing
```

Verify the GPU is free:
```bash
# If rocm-smi is available on the node:
rocm-smi --showmemuse
# GPU VRAM% should drop back to the baseline (no inference pod running)
```

---

## Step 5 — Deploy the working inference pod

This step deploys vLLM using `kyuz0/vllm-therock-gfx1151:stable` — a Fedora 43
container built on AMD's TheRock nightly ROCm with PyTorch compiled specifically
for `gfx1151`. It mounts the weights PVC from Step 3.

### 5a — Update the PVC name in the manifest

Replace `<PVC_NAME>` in the manifest below with the actual PVC name you recorded in
Step 3 (e.g. `hf---microsoft-phi-4-mini-instruct-2e07ce61bb-cache-89d7670f`).

Also replace `<NODE_IP>` with your Kubernetes node's internal IP:

```bash
kubectl get nodes -o wide | awk 'NR>1 {print $6}'
# Example: 192.168.32.13
```

> **Non-standard architectures (e.g. Qwen3.6-27B):**  
> Models with custom code (GatedDeltaNet, hybrid linear-attention) require two
> extra vLLM CLI args in the Deployment `command` block:
> - `--trust-remote-code` — loads the custom model class from HuggingFace
> - `--reasoning-parser qwen3` — parses Qwen thinking/reasoning tokens  
> Without `--trust-remote-code`, vLLM refuses to load the model.  
> For Qwen3.6-27B also increase `gpu-memory-utilization` to `0.55`, container
> `memory` to `32Gi`, `dshm` to `16Gi`, and readiness `initialDelaySeconds` to
> `300` (27 B load takes 10–20 min).

```yaml
# phi4-mini-deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: phi4-mini-vllm
  namespace: default
  labels:
    app: phi4-mini-vllm
    aim.eai.amd.com/platform: gfx1151
    aim.eai.amd.com/model: microsoft-phi-4-mini-instruct
spec:
  replicas: 1
  selector:
    matchLabels:
      app: phi4-mini-vllm
  template:
    metadata:
      labels:
        app: phi4-mini-vllm
        aim.eai.amd.com/platform: gfx1151
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: feature.node.kubernetes.io/aim-accelerator.R9700
                    operator: Exists
      volumes:
        - name: model-weights
          persistentVolumeClaim:
            claimName: <PVC_NAME>   # ← replace with actual PVC name from Step 3
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 8Gi
      containers:
        - name: vllm
          image: kyuz0/vllm-therock-gfx1151:stable
          command:
            - python
            - -m
            - vllm.entrypoints.openai.api_server
            - --model
            - /model
            - --served-model-name
            - microsoft/Phi-4-mini-instruct
            - --attention-backend
            - ROCM_ATTN
            - --enforce-eager
            - "true"
            - --gpu-memory-utilization
            - "0.35"
            - --max-model-len
            - "8192"
            - --max-num-seqs
            - "32"
            - --tensor-parallel-size
            - "1"
            - --host
            - "0.0.0.0"
            - --port
            - "8000"
          env:
            - name: HSA_OVERRIDE_GFX_VERSION
              value: "11.5.1"
            - name: HSA_ENABLE_SDMA
              value: "0"
            - name: MIOPEN_FIND_ENFORCE
              value: "1"
            - name: PYTORCH_ROCM_ARCH
              value: gfx1151
            - name: GPU_ARCHS
              value: gfx1151
            - name: TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL
              value: "1"
            - name: VLLM_ROCM_USE_AITER
              value: "0"
            - name: VLLM_ROCM_USE_AITER_MHA
              value: "0"
            - name: VLLM_ROCM_USE_AITER_RMSNORM
              value: "0"
            - name: VLLM_ROCM_USE_AITER_LINEAR
              value: "0"
            - name: VLLM_ROCM_USE_AITER_MOE
              value: "0"
            - name: VLLM_ROCM_USE_AITER_UNIFIED_ATTENTION
              value: "0"
            - name: VLLM_DO_NOT_TRACK
              value: "1"
            - name: VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS
              value: "900"
          ports:
            - containerPort: 8000
              name: http
          volumeMounts:
            - name: model-weights
              mountPath: /model
            - name: dshm
              mountPath: /dev/shm
          resources:
            limits:
              amd.com/gpu: "1"
            requests:
              amd.com/gpu: "1"
              cpu: "4"
              memory: 16Gi
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 120
            periodSeconds: 20
            timeoutSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 180
            periodSeconds: 30
            timeoutSeconds: 15
            failureThreshold: 5
---
apiVersion: v1
kind: Service
metadata:
  name: phi4-mini-vllm
  namespace: default
  labels:
    app: phi4-mini-vllm
spec:
  selector:
    app: phi4-mini-vllm
  ports:
    - name: http
      port: 8000
      targetPort: 8000
      nodePort: 30400
  type: NodePort
```

```bash
kubectl apply -f phi4-mini-deployment.yaml
```

### 5b — Wait for the pod to become Ready

```bash
kubectl get pods -n default -l app=phi4-mini-vllm -w
```

Expected progression:
```
NAME                             READY   STATUS              AGE
phi4-mini-vllm-xxx               0/1     ContainerCreating   10s   ← image pull (~8 min first time)
phi4-mini-vllm-xxx               0/1     Running             8m    ← vLLM initialising
phi4-mini-vllm-xxx               1/1     Running             10m   ← Ready ✓
```

> **First run:** The `kyuz0/vllm-therock-gfx1151:stable` image is ~10 GB. Expect
> 5–10 minutes for the initial pull. Subsequent restarts are fast.

Watch vLLM startup logs (look for `Application startup complete`):

```bash
POD=$(kubectl get pods -n default -l app=phi4-mini-vllm -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default "$POD" -f
```

Successful startup ends with:
```
(APIServer pid=1) INFO:     Application startup complete.
(APIServer pid=1) INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
```

---

## Step 6 — Register in AI Workbench (`AIMModel`)

An `AIMModel` with the `aim.eai.amd.com/external-endpoint` annotation registers the
NodePort endpoint in AI Workbench, making it appear alongside catalog models.

Replace `<NODE_IP>` with the same IP from Step 5:

```yaml
# phi4-mini-aimmodel.yaml
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMModel
metadata:
  name: phi4-mini-vllm
  namespace: default
  annotations:
    aim.eai.amd.com/display-name: Phi-4-mini-instruct 3.8B (gfx1151 vLLM)
    aim.eai.amd.com/external-endpoint: http://<NODE_IP>:30400   # ← replace NODE_IP
    aim.eai.amd.com/model-id: microsoft-phi-4-mini-instruct
spec:
  discovery:
    extractMetadata: false
    createServiceTemplates: false
  image: amdenterpriseai/aim-base:0.11
  imageMetadata:
    baseImageRef: docker.io/kyuz0/vllm-therock-gfx1151:stable
    model:
      canonicalName: microsoft/Phi-4-mini-instruct
      hfTokenRequired: false
      tags:
        - text-generation
        - chat
        - instruction
      descriptionFull: >
        Phi-4-mini-instruct (3.8B) dense SLM by Microsoft. Served via vLLM on
        gfx1151 (Strix Halo / R9700) using TheRock nightly PyTorch build.
        OpenAI-compatible endpoint. No HuggingFace token required.
```

```bash
kubectl apply -f phi4-mini-aimmodel.yaml
kubectl get aimmodel phi4-mini-vllm -n default
# Expected: STATUS=Ready
```

---

## Step 7 — End-to-end tests

Substitute `<NODE_IP>` with your node IP:

```bash
BASE="http://<NODE_IP>:30400"
```

### Test 1 — Health check

```bash
curl -sf "$BASE/health" && echo "OK"
# Expected: OK  (empty body with 200 status)
```

### Test 2 — List models

```bash
curl -s "$BASE/v1/models" | python3 -m json.tool
```

Expected response:
```json
{
  "object": "list",
  "data": [
    {
      "id": "microsoft/Phi-4-mini-instruct",
      "object": "model",
      "max_model_len": 8192,
      ...
    }
  ]
}
```

### Test 3 — Chat completions

```bash
curl -s "$BASE/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "microsoft/Phi-4-mini-instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant. Be concise."},
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "max_tokens": 50,
    "temperature": 0
  }' | python3 -m json.tool
```

### Test 4 — Streaming response (SSE)

```bash
curl -s "$BASE/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "microsoft/Phi-4-mini-instruct",
    "messages": [{"role": "user", "content": "Count to 5."}],
    "max_tokens": 30,
    "stream": true
  }'
```

### Test 5 — In-cluster test via temporary pod

```bash
kubectl run aim-test --rm -it --restart=Never \
  --image=curlimages/curl:8.18.0 \
  -n default \
  -- curl -s http://phi4-mini-vllm.default.svc.cluster.local:8000/v1/models
```

---

## Adapting this guide to a different model

To use a different model, change the following values consistently across all five
manifests:

| Field to change | Manifests affected |
|-----------------|--------------------|
| `metadata.name` → new slug | `AIMClusterModel`, `AIMClusterProfile` |
| `spec.imageMetadata.model.canonicalName` | `AIMClusterModel`, `AIMModel` |
| `spec.modelId` / `spec.aimId` | `AIMClusterProfile` |
| `spec.modelSources[0].modelId` + `sourceUri` | `AIMClusterProfile` |
| `spec.profile.name` | `AIMService` |
| `spec.precision` | `AIMClusterProfile`, `recommendedDeployments` in `AIMClusterModel` |
| `spec.resources.requests.memory` | `AIMClusterProfile` (`32Gi` SLM, `64Gi` for 27 B) |
| `engineArgs.max-model-len` | `AIMClusterProfile`, `Deployment` command args |
| `engineArgs.gpu-memory-utilization` | `AIMClusterProfile`, `Deployment` command args |
| `--served-model-name` | `Deployment` command args |
| `--trust-remote-code` | `Deployment` command args (required for non-standard architectures) |
| `--reasoning-parser` | `Deployment` command args (e.g. `qwen3` for Qwen thinking models) |
| `claimName` | `Deployment` volumes |
| `nodePort` | `Service` (use unique port per model, e.g. 30400, 30401) |
| `aim.eai.amd.com/model-id` annotation | `AIMModel` |
| `aim.eai.amd.com/external-endpoint` | `AIMModel` (must match `nodePort`) |

### Sizing `gpu-memory-utilization`

On a 128 GiB LPDDR5x system, GPU and system RAM are unified. Total addressable VRAM
is reported as ~128 GiB but the **effective free VRAM depends on other workloads**
sharing the same pool. Use `rocm-smi --showmemuse` to check current allocation and
set `gpu-memory-utilization` conservatively:

| Scenario | Recommended value |
|----------|-------------------|
| Only this model, no other GPU workloads | `0.75` |
| Alongside host `llama.cpp` serving (~50 GB) | `0.35` |
| Multiple AIM models co-deployed | `0.20`–`0.30` |

Formula: `gpu-memory-utilization × total_vram_GiB ≤ free_vram_GiB`

| Model size | Typical `gpu-memory-utilization` (solo workload) |
|------------|--------------------------------------------------|
| ≤ 8 B (fp16) | `0.35`–`0.40` |
| 27 B (bf16) | `0.55` |
| Alongside host llama.cpp (~50 GB) | subtract ~0.20 from solo value |

### Qwen/Qwen3.6-27B example

A complete second deployment following this guide is available at:

| Resource | Path |
|----------|------|
| Manifests | `manifests/aim/qwen3-6-27b/` |
| Deploy script | `scripts/10-qwen3-6-27b.sh` |
| NodePort | `30401` |

Key differences from the Phi-4-mini example:

- `precision: bf16` (not fp16)
- Weights PVC ~56 GiB (download takes 30–60 min)
- `--trust-remote-code` and `--reasoning-parser qwen3` required
- Hybrid GatedDeltaNet architecture: KV-cache only on 16 of 64 layers, so memory
  overhead at 32K context is modest (~2 GiB) despite the 27 B parameter count
- Disable thinking in API calls: `"chat_template_kwargs": {"enable_thinking": false}`
- MTP speculative decoding enabled via `--speculative-config '{"model":"/model","num_speculative_tokens":1}'`
  (uses built-in `Qwen3_5MTP` draft head; ~1.7× TPS on gfx1151, ~90% draft acceptance)
- `AIMClusterServiceTemplate` required for the AI Workbench catalog **Deploy** button
  (`createServiceTemplates: false` on the stub model skips auto-generation). Apply
  `manifests/aim/qwen3-6-27b/aim-clusterservicetemplate.yaml` and ensure R9700 labels
  (`scripts/03b-gfx1151-aim-labels.sh`). Do not set both `profileId` and `customProfile`
  on the template — that duplicates `AIM_PROFILE_ID` and blocks discovery.

---

## Teardown

Remove all resources in reverse order:

```bash
# Inference pod and service
kubectl delete deployment phi4-mini-vllm -n default
kubectl delete service phi4-mini-vllm -n default

# AI Workbench registration
kubectl delete aimmodel phi4-mini-vllm -n default

# AIMService (this also deletes the weights PVC — omit if you want to keep weights)
kubectl delete aimservice phi4-mini -n default

# Wait for PVC deletion to complete
kubectl get pvc -n default | grep phi

# AIM catalog entries (cluster-scoped)
kubectl delete aimclusterprofile phi4-mini-r9700-gfx1151-latency
kubectl delete aimclustermodel microsoft-phi-4-mini-instruct
```

To keep the weights PVC for a future redeployment, delete the `AIMService` with the
`--cascade=orphan` flag before removing it (so the PVC is not garbage-collected):

```bash
kubectl delete aimservice phi4-mini -n default --cascade=orphan
```

---

## Troubleshooting

### `AIMClusterProfile` stuck at `NotAvailable`

```bash
kubectl describe aimclusterprofile phi4-mini-r9700-gfx1151-latency | grep -A5 "Status"
```

**Cause:** R9700 node label missing.  
**Fix:** Re-apply the label from the Prerequisites section. Labels must be re-applied
after node reboots.

### `AIMService` InferenceService pod keeps crash-looping

This is **expected** on gfx1151. The `aim-base:0.11` image does not include
gfx1151-compiled PyTorch kernels. The crash-loop does not affect the weight download
(`AIMArtifact`) or the PVC. Proceed to Step 4 to free the GPU and deploy the
working pod.

To suppress the crash-loop noise while waiting for the download, you can scale down
the InferenceService immediately:

```bash
kubectl scale replicaset -n default \
  -l "serving.kserve.io/inferenceservice=phi4-mini" --replicas=0
```

### NodePort returns connection refused despite pod `Ready`

If the pod passes its readiness probe but `curl http://<NODE_IP>:<nodePort>/health`
fails, check whether the EndpointSlice is stale (common after a 30+ minute vLLM
startup — the slice was created while the pod was still `notReady`):

```bash
kubectl get endpointslice -n default -l kubernetes.io/service-name=<service-name> \
  -o jsonpath='{.items[0].endpoints[0].conditions.ready}{"\n"}'
# Expected: true

# If false, delete the slice — the controller recreates it within seconds:
kubectl delete endpointslice -n default -l kubernetes.io/service-name=<service-name>
```

### `phi4-mini-vllm` pod stuck in `ContainerCreating`

```bash
kubectl describe pod -n default -l app=phi4-mini-vllm | tail -20
```

- **`Pulling image...`** — Normal; the ~10 GB image is downloading. Wait 5–10 minutes.
- **`FailedScheduling: Insufficient amd.com/gpu`** — Another pod is holding the GPU.
  Find it with `kubectl get pods -A | grep -v Completed` and check GPU usage with
  `rocm-smi --showmemuse`. Scale down the competing pod.
- **`cannot find PVC`** — The `claimName` in the Deployment does not match the actual
  PVC name. Re-run `kubectl get pvc -n default` and update the manifest.

### vLLM `ValueError: Free memory ... is less than desired GPU memory utilization`

Another process holds VRAM. Lower `--gpu-memory-utilization` in the Deployment
command args (e.g. from `0.35` to `0.25`) and re-apply:

```bash
kubectl set env deployment/phi4-mini-vllm -n default \
  # gpu-memory-utilization is a CLI arg, not an env var — patch the deployment instead:
kubectl patch deployment phi4-mini-vllm -n default --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/command/9","value":"0.25"}]'
```

Or simply edit and re-apply `phi4-mini-deployment.yaml` with the new value.

### `RuntimeError: Engine core initialization failed` with no other log output

This is the V1 EngineCore subprocess crashing silently. Ensure `VLLM_USE_V1: "0"` is
set in the Deployment `env` section (not just in `AIMClusterProfile.engineEnv`). In
the manifest above it is already set via `VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS` context
— but double-check:

```bash
kubectl exec -n default \
  "$(kubectl get pods -n default -l app=phi4-mini-vllm -o jsonpath='{.items[0].metadata.name}')" \
  -- env | grep VLLM_USE_V1
```

If missing, add it explicitly to the Deployment env block:
```yaml
- name: VLLM_USE_V1
  value: "0"
```

### `torch.randn segfault` inside `aim-base:0.11` debug pod

This is the root cause of all AIMService failures on gfx1151. The `aim-base:0.11`
PyTorch build does not include compiled kernels for `gfx1151`. The solution is the
custom AIM image described below.

---

## Custom AIM Image for Managed Deployment (gfx1151)

> **Status:** Implemented — 2026-06-12. Enables full MI300X-style managed `AIMService`
> flow on `gfx1151` without a separate plain `Deployment`.

### Problem summary

The three-layer hybrid approach above has one significant limitation: the `AIMService`
InferenceService pod crashes because `aim-base:0.11` bundles CDNA-compiled PyTorch.
This means:

- **Workbench Deploy button** creates a crashing pod
- **HTTPRoutes** are not provisioned by the managed flow
- The external `AIMModel` endpoint is a workaround, not the intended path

### Solution: custom AIM image

`images/aim-gfx1151-qwen3-6-27b/Dockerfile` creates a custom image that combines:

| Layer | Source | Purpose |
|-------|--------|---------|
| `aim-runtime` Python package | `amdenterpriseai/aim-base:0.11` (build stage) | Reads profile ConfigMap, sets env vars, exec()s into vLLM |
| vLLM + ROCm + gfx1151 PyTorch | `kyuz0/vllm-therock-gfx1151:stable` (runtime base) | Actual GPU inference stack |

`aim-runtime` is pure Python (no GPU dependencies) — it can be extracted from
`aim-base` and run on any Python environment. When the AIM operator launches the
predictor pod, it mounts the profile YAML as a ConfigMap and sets `AIM_PROFILE_ID`.
`aim-runtime` reads that YAML, assembles the vLLM CLI arguments, and `os.execv()`s
into `vllm serve`. The custom image intercepts this flow and runs vLLM against the
gfx1151-compiled PyTorch stack.

### Build and push (one-time, ~5-10 min)

```bash
# Registry deployment (if not running)
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: registry}
  template:
    metadata:
      labels: {app: registry}
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: data
          mountPath: /var/lib/registry
      volumes:
      - name: data
        hostPath:
          path: /var/lib/rancher/registry-data
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: kube-system
spec:
  type: NodePort
  selector: {app: registry}
  ports:
  - port: 5000
    targetPort: 5000
    nodePort: 32000
EOF

# RKE2 registries config
sudo tee /etc/rancher/rke2/registries.yaml <<'EOF'
mirrors:
  "192.168.32.13:32000":
    endpoint:
      - "http://192.168.32.13:32000"
  "localhost:32000":
    endpoint:
      - "http://localhost:32000"
EOF
sudo systemctl restart rke2-server

# Build + push (first run pulls ~15 GB of base images)
IMAGE=192.168.32.13:32000/aim-gfx1151-qwen3-6-27b:0.11-therock
docker build -t "$IMAGE" images/aim-gfx1151-qwen3-6-27b/
docker push "$IMAGE"
```

The `scripts/10-qwen3-6-27b.sh` script does this automatically (Step 0).

### Gateway fix (AIMRuntimeConfig)

The cluster-scoped `AIMClusterRuntimeConfig/default` (Helm-managed) references
`kgateway-system/https` which does not exist on this cluster. The actual Gateway
is in `envoy-gateway-system/https`. A namespace-scoped `AIMRuntimeConfig` overrides this:

```bash
kubectl apply -f manifests/aim/qwen3-6-27b/aim-runtimeconfig-demo.yaml
```

This is applied automatically by Step 3c of `scripts/10-qwen3-6-27b.sh`.

### Manifest changes (relative to hybrid approach)

| File | Change |
|------|--------|
| `aim-clusterprofile.yaml` | `image:` → `192.168.32.13:32000/aim-gfx1151-qwen3-6-27b:0.11-therock`; `max-num-seqs: 16`; added `speculative-config` (MTP) |
| `aim-clustermodel.yaml` | annotations + `image:` → local registry |
| `aim-clusterservicetemplate.yaml` | added `speculative-config` (MTP); `max-num-seqs: 16` |
| `aim-runtimeconfig-demo.yaml` | **new** — fixes gateway ref for `demo` namespace |
| `images/aim-gfx1151-qwen3-6-27b/Dockerfile` | **new** — multi-stage build |
| `scripts/10-qwen3-6-27b.sh` | adds Step 0 (image build), Step 3c (gateway fix), managed predictor wait, hybrid fallback via `SKIP_MANAGED_BUILD=1` |

### MTP speculative decoding

Qwen3.6-27B includes a built-in `Qwen3_5MTP` multi-token prediction head. With vLLM
0.19.2rc1+ on gfx1151 this can be enabled for improved throughput:

```python
speculative_config = {
    "model": "/workspace/cache/Qwen/Qwen3.6-27B",  # same model = MTP head
    "num_speculative_tokens": 1,
}
```

This is set in both `aim-clusterprofile.yaml` and `aim-clusterservicetemplate.yaml`.
`max-num-seqs` is reduced to 16 (from 32) for memory stability with MTP active.

---

## Reference

| Resource | API version | Scope | Purpose |
|----------|-------------|-------|---------|
| `AIMClusterModel` | `aim.eai.amd.com/v1alpha1` | Cluster | Catalog entry |
| `AIMClusterProfile` | `aim.eai.amd.com/v1alpha2` | Cluster | Runtime config + download source |
| `AIMClusterServiceTemplate` | `aim.eai.amd.com/v1alpha1` | Cluster | Workbench catalog Deploy button |
| `AIMRuntimeConfig` | `aim.eai.amd.com/v1alpha1` | Namespace | Gateway + routing overrides |
| `AIMService` | `aim.eai.amd.com/v1alpha2` | Namespace | Managed deployment trigger |
| `AIMArtifact` | `aim.eai.amd.com/v1alpha1` | Namespace | Download job + PVC (managed by operator) |
| `AIMModel` | `aim.eai.amd.com/v1alpha1` | Namespace | External endpoint registration (hybrid only) |
| `Deployment` + `Service` | `apps/v1`, `v1` | Namespace | Inference pod (hybrid fallback only) |

### Image reference

| Image | Source | Purpose |
|-------|--------|---------|
| `amdenterpriseai/aim-base:0.11` | Docker Hub | Build stage only — extracts `aim-runtime` |
| `kyuz0/vllm-therock-gfx1151:stable` | Docker Hub | Runtime base — vLLM 0.19.2rc1 + gfx1151 PyTorch |
| `192.168.32.13:32000/aim-gfx1151-qwen3-6-27b:0.11-therock` | Local cluster registry | Custom managed AIM image |

### Validated environment

| Component | Version |
|-----------|---------|
| GPU | AMD Radeon 8060S (gfx1151 / Strix Halo) |
| Kernel | linux-oem-24.04d (required for stable HIP on RDNA 3.5) |
| ROCm | 7.2.x |
| AIM Engine | 0.11.0 |
| vLLM | 0.19.2rc1 (in `kyuz0/vllm-therock-gfx1151:stable`) |
| Kubernetes | RKE2 v1.34.1 |
