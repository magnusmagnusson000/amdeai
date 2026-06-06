# Call flow: ggml-org/llama.cpp (local inference)

**Source:** `~/eai-build/llama.cpp/` (branch `gfx1151-rdna35-tuning` for HIP fixes)  
**Script:** `scripts/07-llama-cpp.sh`  
**Upstream guide:** [gfx1151-upstream-pr-guide.md](../gfx1151-upstream-pr-guide.md)

## Backends on gfx1151

| Backend | Build dir | Default for | Env |
|---------|-----------|-------------|-----|
| **Vulkan** | `build-vulkan/` | Gemma 4 26B-A4B (MoE) | `EAI_LLAMA_BACKEND=vulkan` |
| **HIP/ROCm** | `build-hip/` | SLMs, cluster-style local tests | `EAI_LLAMA_BACKEND=hip` |

Both backends share the same GGML graph; only the GPU dispatch layer differs.

## Downward path (prompt → hardware) — Vulkan (Gemma 4 default)

1. **HTTP:** `POST /v1/chat/completions` → `tools/server`
2. **Graph:** `llama-graph.cpp` — matmul, RoPE, MoE router (Gemma 4-A4B)
3. **Backend:** `ggml-vulkan` → Mesa RADV → DRM → gfx1151

## Downward path — HIP (standard ROCm, after gfx1151 patches)

1. Same HTTP and graph build as above.
2. **Backend:** `ggml-cuda` (HIP) → `hipLaunchKernel` → ROCclr → KFD → gfx1151
3. **gfx1151 patches (branch `gfx1151-rdna35-tuning`):**
   - `mmvq.cu` — `MMVQ_PARAMETERS_RDNA3_5` (`nwarps=4`)
   - `mmq.cuh` — tile sizes 48×64, `nwarps=4`
   - `topk-moe.cu` — disable fused MoE on RDNA3_5 (workaround #21416)

## Upward path

Fence/event → sampling → SSE/JSON → AI Workbench backend → UI.

## Build commands

```bash
# Vulkan (default script backend for Gemma)
cmake -B build-vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build-vulkan -j$(nproc)

# HIP (gfx1151)
cmake -B build-hip -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 -DCMAKE_BUILD_TYPE=Release
cmake --build build-hip -j$(nproc)
```

## SLM test (before/after patches)

```bash
./build-hip/bin/llama-bench --model ~/models/Qwen3-0.6B-Q4_K_M.gguf \
  --n-gpu-layers 99 -p 512 -n 128 -r 3
```

## Files to read

| Step | Path |
|------|------|
| HTTP | `tools/server/server.cpp` |
| MoE graph | `src/models/gemma4.cpp`, `src/llama-graph.cpp` |
| HIP kernels | `ggml/src/ggml-cuda/mmvq.cu`, `mmq.cuh`, `topk-moe.cu` |
| Vulkan | `ggml/src/ggml-vulkan/` |

## Relation to standard EAI path

Cluster inference uses **vLLM in GPU pods** (Kaiwo path), not host llama-server. Host llama.cpp serves the Workbench **AIMModel** endpoint at `http://<node-ip>:8080`.
