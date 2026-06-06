# End-to-end call flow: chat prompt → hardware → response

This document describes **two inference paths** on the Z13 gfx1151 stack:

1. **Standard EAI path** — ROCm HIP via Kaiwo + vLLM (cluster GPU pods)
2. **Local host path** — llama.cpp on the node (Vulkan for Gemma 4; HIP for SLMs after gfx1151 patches)

See also: [gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md) for source patches and upstream PR instructions.

## Standard path — ROCm HIP via Kaiwo + vLLM

```mermaid
sequenceDiagram
    participant User
    participant AIWB as AI_Workbench
    participant Kaiwo as Kaiwo_operator
    participant Kueue as Kueue
    participant Plugin as k8s_device_plugin
    participant Pod as GPU_pod_vLLM
    participant HIP as ROCm_HIP
    participant KFD as amdgpu_KFD
    participant HW as gfx1151

    User->>AIWB: Submit chat or KaiwoJob
    AIWB->>Kaiwo: Create workload
    Kaiwo->>Kueue: ClusterQueue amd_gfx1151
    Kueue-->>Kaiwo: Admitted
    Kaiwo->>Plugin: Schedule amd.com/gpu=1
    Plugin-->>Pod: Mount /dev/kfd /dev/dri
    User->>Pod: POST /v1/chat/completions
    Pod->>HIP: hipLaunchKernel hipblasGemm
    HIP->>KFD: KFD ioctl IB submit
    KFD->>HW: GFX ring execution
    HW-->>Pod: Logits
    Pod-->>User: Token stream
```

## Local host path — llama.cpp (Workbench → AIMModel → host :8080)

```mermaid
sequenceDiagram
    participant User
    participant AIWB_UI as AI_Workbench_UI
    participant AIWB_API as AI_Workbench_API
    participant AIM as AIM_Engine
    participant CR as AIMModel_CR
    participant HTTP as llama_server_8080
    participant GGML as GGML_graph
    participant GPU as Vulkan_or_HIP
    participant KMD as amdgpu_kernel
    participant HW as gfx1151

    User->>AIWB_UI: Chat prompt
    AIWB_UI->>AIWB_API: Authenticated API
    AIWB_API->>AIM: Resolve model
    AIM->>CR: Read endpoint url
    CR-->>AIM: http://HOST:8080 OpenAI
    AIWB_API->>HTTP: POST /v1/chat/completions
    HTTP->>GGML: Tokenize decode graph
    GGML->>GPU: Vulkan RADV or HIP ROCm
    GPU->>KMD: DRM or KFD ioctl
    KMD->>HW: Execute kernels
    HW-->>HTTP: Tokens SSE
    HTTP-->>User: Assistant reply
```

## Path selection on gfx1151

| Scenario | Backend | Notes |
|----------|---------|-------|
| Cluster vLLM / PyTorch job | ROCm HIP | Standard EAI path; env vars in GPU plugin |
| Local Gemma 4 26B-A4B | **Vulkan** (default) | HIP MoE bug [#21416](https://github.com/ggml-org/llama.cpp/issues/21416); use `EAI_LLAMA_BACKEND=vulkan` |
| Local SLM (Qwen3-0.6B, phi-4-mini) | HIP (after patches) | Branch `gfx1151-rdna35-tuning`; `EAI_LLAMA_BACKEND=hip` |
| Local Gemma 4 after G1–G3 patches | HIP (test) | Re-test with unfused MoE path |

## Layer summary

| Layer | Component | Standard (HIP) | Local host |
|-------|-----------|----------------|------------|
| 7 UI | AI Workbench | Chat / job submit | Chat |
| 6 Control | AIM Engine + AIMModel | Optional routing | Endpoint CR → :8080 |
| 5 Orchestration | Kaiwo + Kueue | **Hot path** | Not used |
| 4 Platform | k3s, MetalLB, cert-manager | TLS, Services | Egress to host IP |
| 3 GPU | k8s-device-plugin | **Hot path** | Not used |
| 1 Inference | vLLM or llama-server | Pod HIP | Host Vulkan/HIP |
| 0 HW | gfx1151 + ROCm | KFD | DRM (Vulkan) or KFD (HIP) |

## Per-repository call-flow docs

| Doc | Component |
|-----|-----------|
| [00-prerequisites.md](call-flows/00-prerequisites.md) | Toolchain |
| [01-rocm-host.md](call-flows/01-rocm-host.md) | **ROCm substrate (standard path)** |
| [02-k3s.md](call-flows/02-k3s.md) | Kubernetes runtime |
| [03-k8s-device-plugin.md](call-flows/03-k8s-device-plugin.md) | GPU scheduling |
| [04-platform.md](call-flows/04-platform.md) | Platform Helm charts |
| [05a-cluster-forge.md](call-flows/05a-cluster-forge.md) | GitOps bootstrap |
| [05b-kaiwo.md](call-flows/05b-kaiwo.md) | **Standard inference orchestration** |
| [06a-aim-engine.md](call-flows/06a-aim-engine.md) | AIM Engine |
| [06b-airm-aiwb.md](call-flows/06b-airm-aiwb.md) | AIRM + AI Workbench |
| [07-llama-cpp.md](call-flows/07-llama-cpp.md) | Local inference hot path |

## Source trees

After build, read code under `~/eai-build/<repo>/`. Sync repos: `bash scripts/sync-eai-build.sh`.
