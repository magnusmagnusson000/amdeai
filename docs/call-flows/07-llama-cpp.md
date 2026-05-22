# Call flow: ggml-org/llama.cpp (inference hot path)

**Source:** `~/eai-build/llama.cpp/`

This is the component that executes **every token** for the local Gemma 4 endpoint.

## Downward path (prompt → hardware)

### 1. HTTP ingress — `tools/server` (llama-server)

- **Entry:** `POST /v1/chat/completions` (OpenAI-compatible JSON).
- **Handler chain:** HTTP server (cpp-httplib or similar) → routes to chat completion handler.
- **Key work:**
  - Parse `messages[]`, `max_tokens`, `stream`.
  - Load **Jinja** chat template (`--jinja`) for Gemma 4 turn format.
  - Tokenize prompt via `llama_tokenize` / vocabulary from GGUF.

**Read next:** `tools/server/server.cpp`, `tools/server/utils.hpp` (chat template application).

### 2. Context and batching — `src/llama-context.cpp`

- Maintains **KV cache** (`--cache-type-k/v q8_0`) across turns.
- Builds a **micro-batch** of tokens for this decode step.
- Sets `n_gpu_layers 999` so weights and compute live on GPU backend.

### 3. Graph build — `src/llama-graph.cpp`, `ggml`

- Constructs a **directed acyclic graph** of tensor ops: matmul, RoPE, softmax, MoE routing (Gemma 4-A4B).
- Scheduler picks backend per tensor: **GGML_BACKEND_DEVICE_TYPE_GPU** → Vulkan.

### 4. Vulkan backend — `ggml/src/ggml-vulkan/`

- **Init:** `vkCreateInstance`, enumerate physical device → AMD Radeon (gfx1151).
- **Per op:** SPIR-V compute pipelines (or cooperative matrices where supported).
- **Submit:** `vkQueueSubmit` with semaphores/fences per graph slice.
- **Memory:** `vkAllocateMemory` for weights, KV, scratch — backed by system RAM visible to iGPU (unified memory).

**Read next:** `ggml/src/ggml-vulkan/ggml-vulkan.cpp`, `ggml-vulkan-shaders/`.

### 5. Userspace driver — Mesa RADV (Vulkan ICD)

- Loader: `libvulkan_radeon.so` (Mesa), not ROCm HIP for this build.
- Translates Vulkan commands to **DRM** ioctl stream.

### 6. Kernel — `amdgpu` (DRM/KFD)

- **DRM:** buffer object (BO) allocation in GTT/VRAM (`amdgpu.gttsize`, `ttm.pages_limit` from GRUB).
- **Scheduler:** submits IBs to GPU ring (GFX, SDMA).
- **Interrupt:** completion fence wakes Vulkan fence.

### 7. Hardware — Radeon 8060S (gfx1151)

- **Shader cores (40 CU)** execute WMMA/vector ops for matmul/attention.
- **Unified LPDDR5x:** weights (~14 GB Q4_K_M) + KV cache in addressable pool.

## Upward path (hardware → response)

1. Fence completion → Vulkan → GGML op done.
2. **Sampling:** logits → softmax → token id (greedy or configured sampler).
3. Repeat decode loop until `max_tokens` or EOS.
4. **Detokenize** → UTF-8 string.
5. **HTTP response:** JSON `choices[].message.content` or SSE chunks.
6. Client (AI Workbench backend) aggregates stream → UI.

## Why not HIP/ROCm for this model

On gfx1151, Gemma 4 MoE via HIP can enter `<unused24>` loop (llama.cpp #21416). Vulkan path is the validated backend for this hardware+model pair.

## Files to set breakpoints / grep

| Step | Path hint |
|------|-----------|
| HTTP | `tools/server/*.cpp` |
| Tokenize | `src/llama-vocab.cpp` |
| Graph | `src/llama-graph.cpp` |
| Vulkan op | `ggml/src/ggml-vulkan/` |
| Device list | `llama-cli --list-devices` |
