# Call flow: Gemma 4 31B (local inference via AIMModel)

**Source:** `~/eai-build/llama.cpp/` (built by `scripts/07-llama-cpp.sh`)  
**Script:** `scripts/08-gemma4-31b.sh`  
**Model:** `~/models/gemma-4-31b-it-Q4_K_M.gguf` (~19 GB Q4_K_M, dense 31B)

## Backends on gfx1151

| Backend | Build dir | Notes | Env |
|---------|-----------|-------|-----|
| **Vulkan** | `build-vulkan/` | Default — safe for Gemma 4 on gfx1151 | `EAI_LLAMA_BACKEND=vulkan` |
| **HIP/ROCm** | `build-hip/` | Dense 31B may work; validate with `validate-hip-gfx1151.sh` | `EAI_LLAMA_BACKEND=hip` |

Gemma 4 31B is a **dense** model (not MoE), so HIP is less risky than the 26B-A4B MoE variant. Vulkan remains the default until HIP is validated on your branch.

## Service

| Property | Value |
|----------|-------|
| systemd unit | `llama-gemma-31b.service` |
| Port | `8081` (26B-A4B uses `:8080`) |
| AIMModel CR | `gemma-4-31b-local` |
| modelId | `gemma-4-31b` |

## AIM registration (AIM Engine v0.2.x)

AIM Engine v0.2.x removed `spec.endpoint` / `displayName` / `capabilities` on `AIMModel`. This script registers:

1. **Service + Endpoints** `gemma-4-31b-local` — bridges cluster pods to host `llama-server` at `<node-ip>:8081`
2. **AIMModel** catalog stub with annotations:
   - `aim.eai.amd.com/external-endpoint`
   - `aim.eai.amd.com/display-name`
   - `aim.eai.amd.com/model-id`

Direct inference (always works):

```bash
curl http://<node-ip>:8081/v1/chat/completions ...
curl http://gemma-4-31b-local.default.svc.cluster.local:8081/v1/chat/completions ...
```

## Upward path

Fence/event → sampling → SSE/JSON → AI Workbench backend → UI.

## Deploy

```bash
# Prerequisite: llama.cpp binaries from step 07
bash scripts/07-llama-cpp.sh

# Model (symlink if already downloaded elsewhere)
mkdir -p ~/models
ln -sf /path/to/google_gemma-4-31B-it-Q4_K_M.gguf ~/models/gemma-4-31b-it-Q4_K_M.gguf

# Deploy 31B service + AIMModel CR
bash scripts/08-gemma4-31b.sh
```

## Validate

```bash
curl -sf http://localhost:8081/health
kubectl describe aimmodel gemma-4-31b-local
curl http://localhost:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-31b","messages":[{"role":"user","content":"Hello"}]}'
```

## Coexistence with 26B-A4B

Both services can run simultaneously on gfx1151 (128 GB unified memory):

| Model | Port | Service |
|-------|------|---------|
| Gemma 4 26B-A4B | 8080 | `llama-gemma.service` |
| Gemma 4 31B | 8081 | `llama-gemma-31b.service` |

## Relation to standard EAI path

Same as `07-llama-cpp.md`: host `llama-server` exposed via **Service + Endpoints** and an **AIMModel** catalog stub (AIM Engine v0.2.x schema). No AIM Engine inference pods are spawned. In-cluster `AIMService` deployment requires an official `amdenterpriseai/aim-google-gemma-4-31b-it` container image (not yet in the AIM catalog).
