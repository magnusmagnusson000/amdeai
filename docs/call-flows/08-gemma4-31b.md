# Call flow: Gemma 4 31B (local GGUF + AIMModel on gfx1151)

**Script:** `scripts/08-gemma4-31b.sh`  
**Model weights:** existing local GGUF only (~19 GiB) — **no Hugging Face download**

## Overview

Gemma 4 31B uses one copy of weights already on disk. Inference runs on the host via llama.cpp; AIM Engine registers the endpoint for AI Workbench:

```
local GGUF  →  llama-server (:8081)  →  Service/Endpoints  →  AIMModel  →  AIWB
```

Managed `AIMService` + `hf://google/gemma-4-31b-it` is **not** used on this machine — it would duplicate weights (~70 GiB HF safetensors vs ~19 GiB GGUF).

## Prerequisites

```bash
# Weights (symlink OK)
ls -lh ~/models/gemma-4-31b-it-Q4_K_M.gguf

# llama.cpp HIP build (from step 07)
EAI_LLAMA_BACKEND=hip bash scripts/07-llama-cpp.sh   # if not already built
```

The script runs `check_disk_before_step` and refuses to start if root free space is below `EAI_MIN_FREE_GB` (default 15 GiB).

## Deploy

```bash
EAI_LLAMA_BACKEND=hip bash scripts/08-gemma4-31b.sh
```

Resources created:

| Resource | Name | Role |
|----------|------|------|
| systemd user unit | `llama-gemma-31b.service` | Host inference from local GGUF |
| `Service` + `Endpoints` | `gemma-4-31b-local` (namespace `demo`) | Cluster → host bridge |
| `AIMModel` | `gemma-4-31b-local` (namespace `demo`) | AIM catalog entry (Ready) |

Optional overrides:

```bash
GEMMA31_MODEL_PATH=/path/to/model.gguf bash scripts/08-gemma4-31b.sh
AIM_NAMESPACE=default bash scripts/08-gemma4-31b.sh   # register elsewhere
```

## Validate

```bash
curl -sf http://localhost:8081/health
kubectl get aimmodel gemma-4-31b-local -n demo
kubectl describe aimmodel gemma-4-31b-local -n demo
curl -s http://localhost:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-31b","messages":[{"role":"user","content":"Hi"}],"max_tokens":16}'
```

## Coexistence with 26B-A4B

| Model | Script | Port |
|-------|--------|------|
| Gemma 4 26B-A4B | `scripts/07-llama-cpp.sh` | `:8080` |
| Gemma 4 31B | `scripts/08-gemma4-31b.sh` | `:8081` |

## Future: managed AIMService

When AMD ships `amdenterpriseai/aim-google-gemma-4-31b-it` and you want in-cluster vLLM (separate HF weights), add the image to `clusterforge/.../aim-models-0.11.0.yaml`. Do not apply `manifests/aim/gemma-4-31b/` profiles with `hf://` sources on a disk-constrained host.

Reference catalog stub (not applied by default): `manifests/aim/gemma-4-31b/aim-clustermodel.yaml`.
