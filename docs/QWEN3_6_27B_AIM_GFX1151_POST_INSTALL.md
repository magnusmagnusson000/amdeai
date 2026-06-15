# Qwen3.6-27B managed AIMService on gfx1151 — post-Bloom install guide

**Audience:** Host with a **working Cluster Bloom** installation (`bloom-gfx1151.yaml`,
[BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md)).

> **Start here for any new catalog model:** [AIM_CATALOG_MODEL_DEPLOY_GFX1151.md](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md) — checklist, Workbench Deploy flow, post-deploy fixes, and troubleshooting. This document is the **Qwen-specific** deep dive (image build, engine args, smoke tests).

**Goal:** Deploy Qwen/Qwen3.6-27B as a fully managed `AIMService` on a gfx1151 node (Radeon
8060S / R9700, Strix Halo). The model is served via vLLM under the AIM Engine operator in the same
way a production MI300X deployment works: `AIMService → InferenceService → custom AIM image →
aim-runtime → vLLM`.

**Pattern:** Custom AIM container image (aim-runtime from `aim-base:0.11` + gfx1151-compiled vLLM
from `kyuz0/vllm-therock-gfx1151:stable`) pushed to an in-cluster container registry, paired with
an `AIMClusterProfile` that wires the engine arguments, and an `AIMService` that drives the full
managed lifecycle (weight download, InferenceService, HTTPRoute, Workbench catalog entry).

> **Why a custom image?**
> `amdenterpriseai/aim-base:0.11` bundles PyTorch compiled for CDNA (MI300X). On gfx1151 (RDNA 3.5)
> that binary segfaults. `kyuz0/vllm-therock-gfx1151:stable` ships vLLM 0.19.2rc1 with PyTorch
> built for gfx1151 via AMD TheRock nightlies. We copy the pure-Python `aim-runtime` layer from
> `aim-base` onto the gfx1151 vLLM stack to get the best of both images.

---

## Prerequisites (verify Bloom is healthy)

Set your node IP (must match the `DOMAIN` in `bloom-gfx1151.yaml`):

```bash
export NODE_IP=$(hostname -I | awk '{print $1}')
export DOMAIN="${NODE_IP}.nip.io"
```

### Cluster and AIM Engine

```bash
kubectl get nodes
kubectl get pods -n aim-system
kubectl get gateway -n envoy-gateway-system
kubectl wait --for=condition=ready pod --all -n aim-system --timeout=300s
kubectl wait --for=condition=ready pod --all -n aiwb --timeout=300s
```

### AIM Engine CRDs (v1alpha2 required)

```bash
kubectl get crd aimservices.aim.eai.amd.com
kubectl get crd aimclusterprofiles.aim.eai.amd.com
kubectl get crd aimclustermodels.aim.eai.amd.com
kubectl get crd aimruntimeconfigs.aim.eai.amd.com
```

All four must be present before continuing.

### AI Workbench HTTPS

```bash
curl -sk -o /dev/null -w "%{http_code}\n" "https://aiwbui.${DOMAIN}/"
# 200 or 307 (redirect to Keycloak) is OK
```

### Host GPU / ROCm (gfx1151)

```bash
rocminfo | grep gfx1151
# Must show a GPU entry; GTT pool ~128 GiB
```

### Disk space

The predictor container expands to roughly **56 GiB** in the containerd overlay filesystem,
plus model weights (**~52 GiB BF16**) stored in a dedicated PVC. You need at minimum **120 GiB
free** before starting, and **at least 15 GiB free at all times** to avoid the kubelet
`node.kubernetes.io/disk-pressure` NoSchedule taint.

```bash
df -h /
# Verify >= 120 GiB available
```

### Docker and RKE2

Both the Docker daemon and RKE2's containerd must be running:

```bash
sudo systemctl is-active docker rke2-server
# Both should output "active"
```

---

## Step 1 — Deploy the in-cluster container registry

Bloom ships an optional local `registry:2` pod on NodePort 32000. If it is not already running,
deploy it now:

```bash
NODE_IP=$(hostname -I | awk '{print $1}')

# Deploy registry pod and service
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

kubectl -n kube-system rollout status deployment/registry --timeout=120s
```

### Configure Docker to push to the registry over HTTP

```bash
# Add the registry as an insecure mirror for Docker
sudo tee /etc/docker/daemon.json <<EOF
{
  "insecure-registries": ["${NODE_IP}:32000", "localhost:32000"]
}
EOF
sudo systemctl restart docker
sleep 5
docker info | grep -A3 "Insecure Registries"
```

### Configure RKE2 containerd to pull from the registry over HTTP

```bash
sudo mkdir -p /etc/rancher/rke2
sudo tee /etc/rancher/rke2/registries.yaml <<EOF
mirrors:
  "${NODE_IP}:32000":
    endpoint:
      - "http://${NODE_IP}:32000"
  "localhost:32000":
    endpoint:
      - "http://localhost:32000"
EOF

sudo systemctl restart rke2-server
# Wait for the API to come back
for i in $(seq 1 60); do kubectl get nodes &>/dev/null && break; sleep 5; done
kubectl get nodes
```

### Pre-pull the `registry:2` image into RKE2 containerd

Because the registry pod itself needs to start before Docker can push to it, import
`registry:2` into RKE2's containerd so that the pod can start without an external pull:

```bash
docker pull registry:2
docker save registry:2 | \
  sudo /var/lib/rancher/rke2/bin/ctr \
    --address /run/k3s/containerd/containerd.sock \
    -n k8s.io images import -
```

Verify the registry pod is Running:

```bash
kubectl -n kube-system get pod -l app=registry
```

---

## Step 2 — Apply gfx1151 AIM accelerator labels

Bloom labels the node as `MI300X` for Cluster Forge compatibility. The AIM operator uses
`feature.node.kubernetes.io/aim-accelerator.*` labels to schedule `AIMClusterProfile` workloads.
These labels must be added manually for gfx1151 (Strix Halo / R9700):

```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

kubectl label node "${NODE}" \
  feature.node.kubernetes.io/aim-accelerator.R9700=1 \
  amd.com/gpu.device-id=7551 \
  amdeai.com/gpu.device-id.actual=1586 \
  amd.com/gpu.vram=128G \
  kaiwo/gpu-model=gfx1151 \
  kaiwo/nodepool=amd-gfx1151-1gpu \
  --overwrite

kubectl get node "${NODE}" --show-labels | tr ',' '\n' | grep -E "aim-accelerator|gpu"
```

Expected output includes `feature.node.kubernetes.io/aim-accelerator.R9700=1`.

---

## Step 3 — Build the custom AIM image

The custom image layers `aim-runtime` (pure Python) from `aim-base:0.11` onto the gfx1151-capable
vLLM stack from `kyuz0/vllm-therock-gfx1151:stable`.

### Create the Dockerfile

```bash
mkdir -p ~/aim-gfx1151-build
cat > ~/aim-gfx1151-build/Dockerfile <<'DOCKERFILE'
# Custom AIM image for gfx1151 (Strix Halo / Radeon 8060S / R9700)
#
# WHY THIS EXISTS:
#   amdenterpriseai/aim-base:0.11 bundles PyTorch compiled for CDNA (MI300X).
#   On gfx1151 (RDNA 3.5) that PyTorch segfaults.
#
#   kyuz0/vllm-therock-gfx1151:stable provides vLLM 0.19.2rc1 with PyTorch
#   compiled for gfx1151 via AMD TheRock nightlies — this image CAN run
#   inference on gfx1151.
#
# STRATEGY:
#   aim-runtime (/workspace/aim-runtime/src/) is pure Python. No GPU deps.
#   It reads a profile YAML (injected by the AIM operator via ConfigMap) and
#   os.execv()s into vLLM. We copy it verbatim from aim-base and run it on
#   the gfx1151-capable vLLM stack.
#
# RESULT:
#   AIMService → InferenceService → this image → aim-runtime → vLLM 0.19.2rc1
#   Full managed AIM flow on gfx1151, no separate Deployment needed.

# Stage 1: extract aim-runtime (pure Python, no GPU deps) from official image
FROM amdenterpriseai/aim-base:0.11 AS aim-src

# Stage 2: gfx1151-capable inference stack with vLLM 0.19.2rc1
FROM kyuz0/vllm-therock-gfx1151:stable

# Copy the aim-runtime Python package — source only, no GPU dependencies
COPY --from=aim-src /workspace/aim-runtime /workspace/aim-runtime

# DO NOT install from aim-runtime/requirements.txt — it pins huggingface-hub==0.36.x
# which would DOWNGRADE the version that transformers 5.5.x requires (>=1.5.0).
# That downgrade breaks: ImportError: cannot import name 'is_offline_mode' from 'huggingface_hub'
#
# Instead, explicitly upgrade huggingface-hub to a compatible version.
# All other aim-runtime deps (pydantic, click, pyyaml…) are already in the vLLM base image.
RUN pip install --no-cache-dir "huggingface-hub>=1.5.0,<2.0"

# Replicate aim-base environment so aim-runtime finds its config and src package
ENV PYTHONPATH="/workspace/aim-runtime/src"
ENV AIM_CONFIG_PATH="/workspace/aim-runtime/config"
ENV AIM_ALLOW_GENERAL_PROFILE_FALLBACK="true"
ENV AIM_ACCELERATOR_FAMILY="instinct"
ENV AIM_ACCELERATOR_TYPE="gpu"
ENV AIM_UPSTREAM_IMAGE_REF="docker.io/kyuz0/vllm-therock-gfx1151:stable"

# aim-runtime in aim-base:0.11 is a library, not a runnable module — it has no
# __main__.py. Add one so `python -m aim_runtime` works as the container entry point.
# AIMConfig.from_environment() reads AIM_MODEL_ID / AIM_PROFILE_ID / AIM_CACHE_PATH
# from the env vars injected by the AIM operator; serve() calls os.execv() into vLLM.
RUN cat > /workspace/aim-runtime/src/aim_runtime/__main__.py <<'PYEOF'
from aim_runtime import AIMRuntime
from aim_runtime.config import AIMConfig
AIMRuntime(AIMConfig.from_environment()).serve()
PYEOF

# OCI label for AIM operator discovery (mirrors what official aim images set)
LABEL com.amd.aim.model.canonicalName="qwen/qwen3-6-27b"
LABEL com.amd.aim.base.version="0.11"
LABEL com.amd.aim.gfx="gfx1151"

WORKDIR /workspace

# The operator mounts the profile ConfigMap at:
#   /workspace/aim-runtime/profiles/custom/qwen/qwen3-6-27b/
# and injects AIM_PROFILE_ID=custom/qwen/qwen3-6-27b/vllm-r9700-bf16-tp1-latency
# aim-runtime reads that YAML, sets env vars, and os.execv()s into vLLM.
ENTRYPOINT ["python", "-m", "aim_runtime"]
DOCKERFILE
```

### Build and push

Replace `192.168.32.13` with your actual `NODE_IP`:

```bash
NODE_IP=$(hostname -I | awk '{print $1}')
IMAGE="${NODE_IP}:32000/aim-gfx1151-qwen3-6-27b:0.11-therock"

docker build -t "$IMAGE" ~/aim-gfx1151-build/
docker push "$IMAGE"
```

The build pulls ~30 GiB from Docker Hub (one-time). Subsequent rebuilds are fast.

### Verify the image in the registry

```bash
curl -s "http://${NODE_IP}:32000/v2/aim-gfx1151-qwen3-6-27b/tags/list"
# {"name":"aim-gfx1151-qwen3-6-27b","tags":["0.11-therock"]}
```

### Pre-pull the image into RKE2 containerd

KServe (which backs `InferenceService`) pulls through RKE2's containerd, not Docker. Import the
image now so the predictor pod starts immediately without an external pull at scheduling time:

```bash
NODE_IP=$(hostname -I | awk '{print $1}')
IMAGE="${NODE_IP}:32000/aim-gfx1151-qwen3-6-27b:0.11-therock"

sudo /var/lib/rancher/rke2/bin/ctr \
  --address /run/k3s/containerd/containerd.sock \
  -n k8s.io images pull \
  --plain-http \
  "$IMAGE"

# Verify
sudo /var/lib/rancher/rke2/bin/ctr \
  --address /run/k3s/containerd/containerd.sock \
  -n k8s.io images ls | grep aim-gfx1151
```

### Smoke-test the image locally

```bash
NODE_IP=$(hostname -I | awk '{print $1}')
IMAGE="${NODE_IP}:32000/aim-gfx1151-qwen3-6-27b:0.11-therock"

docker run --rm "$IMAGE" \
  python3 -c "
import huggingface_hub, transformers
print('huggingface_hub:', huggingface_hub.__version__)
from transformers import GenerationConfig
print('transformers: OK')
from aim_runtime import AIMRuntime
from aim_runtime.config import AIMConfig
print('aim_runtime: OK')
"
```

Expected output:
```
huggingface_hub: 1.19.0
transformers: OK
aim_runtime: OK
```

---

## Step 4 — Create the AIMClusterModel

This is the AIM catalog entry that makes the model discoverable to the AIM operator:

```bash
NODE_IP=$(hostname -I | awk '{print $1}')

kubectl apply -f - <<EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMClusterModel
metadata:
  name: qwen-qwen3-6-27b
  labels:
    aim.eai.amd.com/origin: manual
    aim.eai.amd.com/platform: gfx1151
  annotations:
    aim.eai.amd.com/source-registry: "${NODE_IP}:32000"
    aim.eai.amd.com/source-repository: aim-gfx1151-qwen3-6-27b
    aim.eai.amd.com/source-tag: "0.11-therock"
spec:
  image: "${NODE_IP}:32000/aim-gfx1151-qwen3-6-27b:0.11-therock"
  discovery:
    extractMetadata: false
    createServiceTemplates: false
  imageMetadata:
    baseImageRef: "${NODE_IP}:32000/aim-gfx1151-qwen3-6-27b:0.11-therock"
    model:
      canonicalName: Qwen/Qwen3.6-27B
      hfTokenRequired: false
      tags:
        - text-generation
        - chat
        - instruction
        - reasoning
      descriptionFull: >
        Qwen3.6-27B (27B) dense hybrid-attention model by Qwen. Validated on gfx1151
        (Strix Halo / R9700) via vLLM with ROCm HIP. No HuggingFace token required.
        Runtime config: qwen3-6-27b-r9700-gfx1151-latency (AIMClusterProfile v1alpha2).
        Requires --trust-remote-code (GatedDeltaNet architecture).
      recommendedDeployments:
        - gpuModel: R9700
          gpuCount: 1
          precision: bf16
          metric: latency
          profileId: qwen3-6-27b-r9700-gfx1151-latency
          description: gfx1151 latency profile — AITER disabled, ROCM_ATTN backend, BF16
EOF

kubectl get aimclustermodel qwen-qwen3-6-27b
```

---

## Step 5 — Create the AIMClusterProfile

The profile tells aim-runtime exactly which vLLM arguments to use and which hardware to target.
It also maps to the profile ConfigMap the AIM operator mounts into the predictor pod.

Key decisions for gfx1151:
- `enforce-eager: true` — disables torch.compile and CUDAGraphs (not yet stable on gfx1151)
- `gpu-memory-utilization: 0.55` — conservative; the 27B model is 52 GiB in a 128 GiB pool
- `attention-backend: ROCM_ATTN` — Triton/ROCM path, AITER disabled (AITER is not reliable on gfx1151)
- `speculative-config` — enables MTP (Multi-Token Prediction) speculative decoding (built into Qwen3.6-27B)
- `reasoning-parser: qwen3` — required for the GatedDeltaNet hybrid architecture

> **Boolean args:** `enforce-eager` and `trust-remote-code` must be YAML native booleans
> (`true`, no quotes). `aim-runtime` maps `bool` values to bare `--flag` arguments; a quoted
> `"true"` string becomes `--enforce-eager true` which vLLM argparse rejects.

```bash
NODE_IP=$(hostname -I | awk '{print $1}')

kubectl apply -f - <<EOF
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMClusterProfile
metadata:
  name: qwen3-6-27b-r9700-gfx1151-latency
  labels:
    aim.eai.amd.com/origin: manual
    aim.eai.amd.com/platform: gfx1151
spec:
  aimId: qwen/qwen3-6-27b
  modelId: Qwen/Qwen3.6-27B
  profileId: qwen3-6-27b-r9700-gfx1151-latency
  engine: vllm
  metric: latency
  precision: bf16
  type: general
  primary: true

  acceleratorModel: R9700
  acceleratorType: gpu
  acceleratorCount: 1
  resources:
    requests:
      cpu: "4"
      memory: 64Gi

  image: "${NODE_IP}:32000/aim-gfx1151-qwen3-6-27b:0.11-therock"

  engineArgs:
    tensor-parallel-size: "1"
    gpu-memory-utilization: "0.55"
    max-model-len: "32768"
    max-num-seqs: "16"
    attention-backend: ROCM_ATTN
    enforce-eager: true
    trust-remote-code: true
    reasoning-parser: qwen3
    speculative-config: '{"model":"/workspace/cache/Qwen/Qwen3.6-27B","num_speculative_tokens":1}'

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
    - modelId: Qwen/Qwen3.6-27B
      sourceUri: hf://Qwen/Qwen3.6-27B
EOF
```

Wait for the profile to become Ready:

```bash
kubectl wait --for=jsonpath='{.status.status}'=Ready \
  aimclusterprofile/qwen3-6-27b-r9700-gfx1151-latency --timeout=120s

kubectl describe aimclusterprofile qwen3-6-27b-r9700-gfx1151-latency | \
  grep -A3 "Status\|HardwareSummary\|MatchingNodes"
# HardwareSummary: 1 x R9700
# MatchingNodes: 1
```

---

## Step 6 — Fix the gateway reference for the namespace

Bloom's `AIMClusterRuntimeConfig` (cluster-scoped) points to `kgateway-system/https`. The actual
gateway on this cluster is in `envoy-gateway-system`. A namespace-scoped `AIMRuntimeConfig`
overrides the cluster default and takes precedence:

Apply this to **every namespace** where you will deploy `AIMService` resources. The example below
covers `default` and `demo`:

```bash
for NS in default demo; do
  kubectl apply -f - <<EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMRuntimeConfig
metadata:
  name: default
  namespace: ${NS}
spec:
  routing:
    enabled: true
    gatewayRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: https
      namespace: envoy-gateway-system
    pathTemplate: '{.metadata.namespace}/{.metadata.labels['"'"'airm.silogen.ai/workload-id'"'"']}'
    requestTimeout: 30m
EOF
done

kubectl get aimruntimeconfig -n default
kubectl get aimruntimeconfig -n demo
```

---

## Step 7 — Deploy the AIMService

Applying the `AIMService` triggers the full managed lifecycle:
1. The AIM operator resolves the profile and creates an `AIMArtifact` download job (downloads
   `Qwen/Qwen3.6-27B` weights from HuggingFace — ~52 GiB, no token required)
2. A PVC is provisioned for the model cache
3. An `InferenceService` and predictor pod are created
4. vLLM starts serving through the AIM API

```bash
kubectl apply -f - <<'EOF'
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMService
metadata:
  name: qwen3-6-27b
  namespace: default
spec:
  profile:
    name: qwen3-6-27b-r9700-gfx1151-latency
  caching:
    mode: Dedicated
  replicas: 1
EOF

kubectl get aimservice qwen3-6-27b -n default
```

---

## Step 8 — Wait for the model to load

### Monitor the download job (first run only)

The AIM operator creates an `AIMArtifact` job that downloads the 52 GiB model weights from
HuggingFace. This takes 20–40 minutes depending on your connection:

```bash
# Watch the download job
kubectl get pods -n default -w | grep -E "artifact|cache|download"

# Follow download progress
ARTIFACT_POD=$(kubectl get pods -n default -o name | grep artifact | head -1)
kubectl logs -n default "${ARTIFACT_POD}" -f
```

The download is complete when `kubectl get pvc -n default | grep qwen3-6-27b` shows a Bound PVC
of ~104 GiB.

### Monitor the predictor pod

Once the PVC is Bound, the predictor pod starts. Model loading takes an additional 2–4 minutes:

```bash
# Watch predictor pod status
kubectl get pods -n default -w | grep predictor

# Follow vLLM startup
PRED_POD=$(kubectl get pods -n default -o name | grep predictor | grep qwen3 | head -1)
kubectl logs -n default "${PRED_POD}" -f
```

Look for these milestone lines:
```
INFO  Loading weights took 85.73 seconds
INFO  Loading drafter model...
INFO  Loading weights took 9.06 seconds
INFO  Model loading took 56.74 GiB memory and 110.4 seconds
INFO  Application startup complete.
```

### Check overall AIMService status

```bash
kubectl get aimservice qwen3-6-27b -n default
# STATUS column should change: Pending → Starting → Running

kubectl describe aimservice qwen3-6-27b -n default | grep -A2 "Type:\|Status:\|Message:"
# All four conditions must be True:
#   ProfileReady
#   RuntimeConfigReady
#   ProfileCacheReady
#   InferenceServiceReady
```

---

## Step 9 — Validate inference

### Direct pod smoke test

```bash
PRED_POD=$(kubectl get pods -n default -o jsonpath='{.items[?(@.metadata.labels.component=="predictor")].metadata.name}' | tr ' ' '\n' | grep qwen3 | head -1)

# List available models
kubectl exec -n default "${PRED_POD}" -- \
  curl -s http://localhost:8000/v1/models | python3 -m json.tool

# Chat completion (thinking mode off — faster for smoke test)
kubectl exec -n default "${PRED_POD}" -- \
  curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3.6-27B",
    "messages": [{"role": "user", "content": "What is the capital of France?"}],
    "max_tokens": 30,
    "temperature": 0,
    "chat_template_kwargs": {"enable_thinking": false}
  }' | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('Answer:', d['choices'][0]['message']['content'])
print('Tokens:', d['usage']['completion_tokens'])
"
```

Expected: `Answer: Paris`

### Via port-forward to the predictor service

```bash
kubectl port-forward -n default svc/$(kubectl get svc -n default -o name | grep qwen3.*predictor | head -1 | cut -d/ -f2) 18080:80 &
sleep 3

curl -s http://localhost:18080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3.6-27B",
    "messages": [{"role": "user", "content": "Name the three primary colors."}],
    "max_tokens": 50,
    "temperature": 0,
    "chat_template_kwargs": {"enable_thinking": false}
  }' | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['choices'][0]['message']['content'])
"

kill %1
```

### Check InferenceService and HTTPRoute

```bash
# InferenceService must show READY=True
kubectl get inferenceservice -n default | grep qwen3

# HTTPRoute must show Accepted
IS_NAME=$(kubectl get inferenceservice -n default -o name | grep qwen3 | head -1 | cut -d/ -f2)
ROUTE_NAME=$(kubectl get httproute -n default -o name | grep qwen3 | head -1 | cut -d/ -f2)
kubectl describe httproute "${ROUTE_NAME}" -n default | grep -A4 "Conditions"
# Type: Accepted  Status: True
# Type: ResolvedRefs  Status: True
```

### Via the Envoy Gateway (HTTPS)

Find the gateway path from the `HTTPRoute`:

```bash
ROUTE_NAME=$(kubectl get httproute -n default -o name | grep qwen3 | head -1 | cut -d/ -f2)
AIM_PATH=$(kubectl get httproute "${ROUTE_NAME}" -n default \
  -o jsonpath='{.spec.rules[0].matches[0].path.value}')
echo "Gateway path: ${AIM_PATH}"

NODE_IP=$(hostname -I | awk '{print $1}')
curl -sk \
  "https://${NODE_IP}${AIM_PATH}/v1/models" | python3 -m json.tool
```

---

## Step 10 — Confirm in AI Workbench UI

Prefer the **catalog-only + UI Deploy** flow documented in [AIM_CATALOG_MODEL_DEPLOY_GFX1151.md](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md#6-deploy). After Deploy confirms, always run:

```bash
bash scripts/ensure-qwen-profile-mount.sh demo
bash scripts/fix-aim-httproute-gateway.sh demo
```

Manual UI check:

1. Open `https://aiwbui.${DOMAIN}` in a browser.
2. Click **Sign in with Keycloak**.
3. Log in as `devuser@${DOMAIN}`.

   Get the password:
   ```bash
   kubectl -n keycloak get secret airm-realm-credentials \
     -o jsonpath='{.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}' | base64 --decode && echo
   ```

4. Go to **Models** (`/models`) or the model picker in **Chat**.
5. Look for **Qwen/Qwen3.6-27B** (or `qwen3-6-27b`).
6. Select it, send a test message such as `"Write a haiku about silicon wafers"`, and confirm a
   streaming reply arrives.

---

## Disk space management

The deployment consumes significant disk:

| Component | Location | Size |
|-----------|----------|------|
| Container image (containerd overlayfs) | `/var/lib/rancher/rke2/agent/containerd/` | ~30 GiB |
| Model weights PVC | `/opt/local-path-provisioner/` | ~104 GiB reserved (52 GiB used) |
| Docker build cache | `/var/lib/docker/` | 1–5 GiB |

To prevent the kubelet `disk-pressure` taint (`node.kubernetes.io/disk-pressure: NoSchedule`)
keep at least **15 GiB free**. On gfx1151 Bloom, apply absolute eviction thresholds (instead of
default ~10–15% of root — ~62–93 GiB on a 624 GiB disk):

```bash
bash scripts/configure-kubelet-disk-eviction.sh
```

This sets `nodefs.available<15Gi` / `imagefs.available<15Gi` hard eviction. Operational checks:

```bash
# Check free space
df -h /

# Remove Docker build cache if tight
docker system prune -f

# Check if disk-pressure taint is active
kubectl describe node | grep Taint
```

If the predictor pod is stuck in `Pending` due to `disk-pressure`:

```bash
# Temporary workaround — add a toleration to the InferenceService
IS_NAME=$(kubectl get inferenceservice -n default -o name | grep qwen3 | head -1 | cut -d/ -f2)
kubectl patch inferenceservice "${IS_NAME}" -n default \
  --type='json' \
  -p='[{"op":"add","path":"/spec/predictor/tolerations","value":[
    {"key":"node.kubernetes.io/disk-pressure","operator":"Exists","effect":"NoSchedule"}
  ]}]'
```

---

## Cleanup / teardown

### Remove the AIMService (stops inference, frees GPU)

```bash
kubectl delete aimservice qwen3-6-27b -n default --ignore-not-found
```

This also deletes the `InferenceService`, predictor pod, and `HTTPRoute`. The model weight PVC is
**retained** (for fast restart). Delete it explicitly if you want to free the 104 GiB:

```bash
kubectl get pvc -n default | grep qwen3-6-27b
kubectl delete pvc -n default <pvc-name>
```

### Remove the AIMClusterProfile and AIMClusterModel

```bash
kubectl delete aimclusterprofile qwen3-6-27b-r9700-gfx1151-latency --ignore-not-found
kubectl delete aimclustermodel qwen-qwen3-6-27b --ignore-not-found
```

### Remove the namespace AIMRuntimeConfig

```bash
kubectl delete aimruntimeconfig default -n default --ignore-not-found
kubectl delete aimruntimeconfig default -n demo --ignore-not-found
```

### Remove the container image from the local registry

```bash
# The registry:2 image supports the Delete API when REGISTRY_STORAGE_DELETE_ENABLED=1
# For a quick removal, just delete and recreate the registry pod's storage
sudo rm -rf /var/lib/rancher/registry-data/docker/registry/v2/repositories/aim-gfx1151-qwen3-6-27b
# Restart registry pod to pick up the deletion
kubectl -n kube-system rollout restart deployment/registry
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `AIMClusterProfile` status `HardwareAvailable: False` | Missing `aim-accelerator.R9700` node label | Re-run Step 2 |
| Predictor pod `Pending: Insufficient amd.com/gpu` | Another pod holds the GPU | `kubectl get pods -A -o json \| python3 -c "..."` — find and delete the GPU holder |
| Predictor pod `Pending: node.kubernetes.io/disk-pressure` | Disk > 95% | Free space; add toleration as described in "Disk space management" |
| `CrashLoopBackOff: No module named aim_runtime.__main__` | Image built without `__main__.py` | Rebuild image from the Dockerfile in Step 3 |
| `CrashLoopBackOff: ImportError: cannot import name 'is_offline_mode'` | `huggingface_hub` version downgraded | Rebuild — ensure `RUN pip install "huggingface-hub>=1.5.0,<2.0"` is in Dockerfile |
| `CrashLoopBackOff: api_server.py: error: unrecognized arguments: true` | `enforce-eager: "true"` (quoted string) in profile | Re-apply `AIMClusterProfile` with unquoted `true` as in Step 5 |
| `ProfileNotFound: 'qwen3-6-27b-r9700-gfx1151-latency' not found` | Profile ConfigMap not mounted at `/workspace/aim-runtime/profiles` | `bash scripts/ensure-qwen-profile-mount.sh demo` |
| `ProfileNotFound: 'custom/qwen/qwen3-6-27b/...' not found` | `customProfile` set on template | Remove `customProfile` from `AIMClusterServiceTemplate` |
| HTTPRoute `Accepted: False` or AIMService stuck **Starting** | Route parent `kgateway-system` | `bash scripts/fix-aim-httproute-gateway.sh demo` |
| HTTPRoute has no status (empty `{}`) | `AIMClusterRuntimeConfig` points to wrong gateway | Apply `AIMRuntimeConfig` in the namespace as in Step 6 |
| Push fails: `http: server gave HTTP response to HTTPS client` | Docker daemon missing insecure registry | Re-run daemon.json + `systemctl restart docker` from Step 1 |
| `docker pull` fails: `failed to register layer: invalid output path` | Docker `overlay2` store corrupted | `sudo systemctl restart docker` — the daemon reinitialises the store |
| vLLM exits: `HSA_OVERRIDE_GFX_VERSION not set` | `containerEnv` missing from profile | Check `engineEnv` vs `containerEnv` blocks in the profile |
| Model outputs `content: null`, only `reasoning` field set | Qwen3 thinking mode; max_tokens too small | Pass `"chat_template_kwargs": {"enable_thinking": false}` or increase `max_tokens` |
| Workbench shows model but chat fails | HTTPRoute not Accepted or gateway path wrong | `bash scripts/fix-aim-httproute-gateway.sh demo`; `kubectl describe httproute -n demo` |

### Useful inspection commands

```bash
# Full AIMService lifecycle status
kubectl describe aimservice qwen3-6-27b -n default

# Profile ConfigMap mounted into the predictor
kubectl get configmap -n default | grep qwen3-6-27b-profile
CM=$(kubectl get configmap -n default -o name | grep qwen3-6-27b-profile | head -1 | cut -d/ -f2)
kubectl get configmap "${CM}" -n default -o jsonpath='{.data}' | python3 -m json.tool

# What vLLM command was generated (see engineArgs translation)
PRED_POD=$(kubectl get pods -n default -o name | grep predictor | grep qwen3 | head -1 | cut -d/ -f2)
kubectl logs -n default "${PRED_POD}" | grep "non-default args"

# GPU memory utilisation once model is loaded
kubectl exec -n default "${PRED_POD}" -- rocm-smi --showmeminfo vram 2>/dev/null || true

# AIMService conditions in tabular form
kubectl get aimservice qwen3-6-27b -n default \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}'
```

---

## Related docs

| Doc | Topic |
|-----|-------|
| [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md) | Bloom install and credentials |
| [GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md](GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md) | Broader custom image strategy for gfx1151 |
| [GEMMA4_AIM_BLOOM_POST_INSTALL.md](GEMMA4_AIM_BLOOM_POST_INSTALL.md) | Gemma 4 AIMModel (GGUF / external endpoint pattern) |
| [AIM_ENGINE_DEEP_DIVE.md](AIM_ENGINE_DEEP_DIVE.md) §8 | AIMClusterProfile and InferenceService internals |
| [call-flows/](call-flows/) | End-to-end request traces for each model |
