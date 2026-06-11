# Telecom Assistant — gfx1151 / Bloom adaptation guide

This document records every change required to run the [AMD Telecom Assistant blueprint](https://github.com/amd-enterprise-ai/solution-blueprints/tree/main/solution-blueprints/telecom-assistant) on the gfx1151 Bloom lab cluster (Asus Z13, Radeon 8060S, RKE2).

**Related docs**

| Topic | Location |
|-------|----------|
| Deploy script | [`scripts/09-telecom-assistant.sh`](../scripts/09-telecom-assistant.sh) |
| Helm overrides | [`manifests/telecom-assistant/values-eai-local.yaml`](../manifests/telecom-assistant/values-eai-local.yaml) |
| Call flow | [`docs/call-flows/09-telecom-assistant.md`](call-flows/09-telecom-assistant.md) |
| Speech manual tests | [`docs/TELECOM_ASSISTANT_SPEECH_TESTING.md`](TELECOM_ASSISTANT_SPEECH_TESTING.md) |
| Gemma 4 LLM backend | [`docs/call-flows/08-gemma4-31b.md`](call-flows/08-gemma4-31b.md) |
| Blueprint upstream deploy | [solution-blueprints `docs/DEPLOYMENT.md`](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/docs/DEPLOYMENT.md) |
| AIM catalog (default models) | [AMD EAI AIM catalog](https://enterprise-ai.docs.amd.com/en/latest/aims/catalog/models.html) |

---

## 1. Repository layout

| Path | Purpose |
|------|---------|
| `~/eai-build/solution-blueprints` | Upstream blueprint (cloned, not forked) |
| `manifests/telecom-assistant/values-eai-local.yaml` | gfx1151-specific Helm overrides (tracked in amdeai) |
| `telecom-assistant` namespace | Isolated deploy target |

Clone (if missing):

```bash
git clone https://github.com/amd-enterprise-ai/solution-blueprints.git ~/eai-build/solution-blueprints
```

---

## 2. LLM: GPT OSS 120B → Gemma 4 31B (host llama-server)

### Upstream default

The parent chart [`values.yaml`](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/values.yaml) deploys:

- Sub-chart `llm` → image `amdenterpriseai/aim-openai-gpt-oss-120b:0.10.0`
- Agent env `LLM_MODEL: openai/gpt-oss-120b`
- Ephemeral storage **512 GiB** on `mlstorage`

See [DEPLOYMENT.md — Default AIM image](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/docs/DEPLOYMENT.md#default-aim-image-and-gpu-compatibility).

### gfx1151 change

| Setting | Value | Reason |
|---------|-------|--------|
| `llm.existingService` | `http://gemma-4-31b-local.demo.svc.cluster.local:8081` | Skip in-cluster LLM pod; use host [`llama-server` on :8081](call-flows/08-gemma4-31b.md) |
| `mainServices.agent.env.LLM_MODEL` | `gemma-4-31b` | OpenAI-compatible model id exposed by llama.cpp |
| `mainServices.agent.env.LLM_API_KEY` | `no-key-required` | No auth on local endpoint |

The `aimchart-llm` sub-chart skips Deployment/Service when `existingService` is set ([sub-chart README](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/charts/aimchart-llm/README.md)).

**Prerequisite:** `bash scripts/08-gemma4-31b.sh` with `AIM_NAMESPACE=demo`.

---

## 3. Embedding: gfx942 → CPU Infinity

### Upstream default

Parent chart sets `embedding.image: michaelf34/infinity:0.0.70-amd-gfx942` (MI300-class).

### gfx1151 change

| Setting | Value | Reason |
|---------|-------|--------|
| `embedding.image` | `michaelf34/infinity:latest` | CPU build; gfx942 ROCm tag does not run on RDNA3.5 |
| `embedding.gpus` | `0` | Avoid claiming the single `amd.com/gpu` |

ChromaDB RAG in the agent uses `intfloat/multilingual-e5-large-instruct` via this service ([blueprint README](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/README.md)).

---

## 4. STT / TTS (voice models)

### Upstream default

| Role | Sub-chart image | GPU |
|------|-----------------|-----|
| STT | `rocm/vllm:v0.14.0_amd_dev` + Qwen3 ASR 1.7B | 1 |
| TTS | `vllm/vllm-omni-rocm:0.14.0` + Qwen3 TTS 1.7B | 1 |

Each sub-chart requests `amd.com/gpu: 1`. On gfx1151 the single GPU is already used by host Gemma (LLM), so Qwen STT/TTS pods cannot run concurrently with the LLM.

### gfx1151 change: CPU-only speech services

We replace the GPU Qwen sub-charts with lightweight CPU services vendored in this repo:

| Service | Image | Model | API |
|---------|-------|-------|-----|
| STT | `telecom-stt-service:local` | faster-whisper `small` (CPU, int8) | OpenAI `/v1/audio/transcriptions` + `/v1/models` |
| TTS | `telecom-tts-service:local` | Kokoro-82M (CPU) | OpenAI `/v1/audio/speech` + `/v1/models` |

Source code: [`services/stt-service/`](../services/stt-service/) and [`services/tts-service/`](../services/tts-service/).

Kubernetes manifests: [`manifests/telecom-assistant/stt-deployment.yaml`](../manifests/telecom-assistant/stt-deployment.yaml), [`manifests/telecom-assistant/tts-deployment.yaml`](../manifests/telecom-assistant/tts-deployment.yaml).

### Helm overrides

| Setting | Value | Reason |
|---------|-------|--------|
| `stt.existingService` | `telecom-stt` | Agent `STT_BASE_URL` → `http://telecom-stt/v1` (chart adds `http://` prefix) |
| `stt.replicas` | `0` | Do not deploy Qwen ASR GPU pod |
| `tts.existingService` | `telecom-tts` | Agent `TTS_BASE_URL` → `http://telecom-tts/v1` |
| `tts.replicas` | `0` | Do not deploy Qwen TTS GPU pod |

The upstream agent init containers poll `STT_BASE_URL/models` and `TTS_BASE_URL/models`. The CPU services expose `/v1/models`, so **no init-container patch is required** — STT, TTS, and host Gemma can all run at the same time.

Deploy script [`scripts/09-telecom-assistant.sh`](../scripts/09-telecom-assistant.sh) builds both images, imports them into RKE2 containerd, and applies the STT/TTS manifests before the Helm chart.

**Voice testing:** see [`TELECOM_ASSISTANT_SPEECH_TESTING.md`](TELECOM_ASSISTANT_SPEECH_TESTING.md) — no GPU handoff or Gemma stop required.

**Automated Playwright tests** use the Client Simulator **text chat** path; integration tests cover STT/TTS `/v1/models` when deployed.

---

## 5. Storage class

### Upstream default

`mlstorage` on enterprise clusters.

### gfx1151 (Bloom)

`mlstorage` exists (`rancher.io/local-path` provisioner). No override to Longhorn required.

| Component | `storageClassName` |
|-----------|-------------------|
| Ephemeral model cache | `mlstorage` |
| ChromaDB PVC | `mlstorage`, 10 GiB |

---

## 6. Gateway / LiveKit WebSocket URL

### Upstream assumption

[`DEPLOYMENT.md`](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/docs/DEPLOYMENT.md#livekit-websocket-url) builds:

```bash
wss://livekit-aimsb-telecom-assistant-${name}$(kubectl get gtw https -n kgateway-system ...)
```

Bloom uses **Envoy Gateway** in `envoy-gateway-system`, not `kgateway-system`.

### gfx1151 change (phase 1)

| Setting | Value |
|---------|-------|
| `http_route.enabled` | `false` |
| `mainServices.frontend.env.LIVEKIT_URL` | `ws://localhost:7880` (port-forward smoke test) |

Port-forwards:

```bash
kubectl port-forward svc/aimsb-telecom-assistant-eai-telecom-frontend 3000:3000 -n telecom-assistant
kubectl port-forward svc/eai-telecom-livekit 7880:7880 -n telecom-assistant
```

### gfx1151 change (phase 2 — browser WebRTC)

1. Add HTTPRoute on Gateway `https` (`envoy-gateway-system`) for frontend + LiveKit signaling.
2. Set `FRONTEND_LIVEKIT_URL=wss://livekit-telecom.<node-ip>.nip.io` (or MetalLB VIP hostname).
3. STUNner per-release Gateway (UDP 3478) routes media — see [STUNner docs](https://github.com/l7mp/stunner/blob/main/docs/GATEWAY.md).

---

## 7. STUNner (WebRTC media gateway)

### Upstream prerequisite

[`install-prerequisites.sh`](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/install-prerequisites.sh) installs cluster-wide STUNner operator into `stunner-system`.

### gfx1151 status

- Operator installed once per cluster (`INSTALL_STUNNER=1` in deploy script).
- Helm release may show `failed` if `--wait` times out; pods can still be Running — verify with `kubectl get pods -n stunner-system`.
- The telecom chart also bundles a STUNner subchart that creates additional operator resources in `telecom-assistant` (duplicate of cluster install). Per-release Gateway/UDPRoute in `telecom-assistant` routes WebRTC media for this deployment.
- Per-release STUNner Gateway/UDPRoute rendered into `telecom-assistant` namespace (`stunner.enabled: true`).

With STUNner, wide UDP **50000–60000** node exposure is usually **not** required ([DEPLOYMENT.md — UDP firewall](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/docs/DEPLOYMENT.md#livekit-udp-firewall-requirement-with-stunner)).

---

## 8. Demo namespace cleanup (pre-deploy)

Removed Workbench AIM clutter that blocked GPU and disk:

| Resource | Action |
|----------|--------|
| `AIMService/wb-aim-e21dff22` | Deleted (GPT OSS 20B, CrashLoop) |
| `AIMService/wb-aim-f358af29` | Deleted (duplicate Gemma AIMService) |
| `AIMTemplateCache/amdenterpriseai-aim-openai-gpt-oss-20b-*` | Deleted (stopped HF 38 GiB re-download) |
| `AIMArtifact/hf---openai-gpt-oss-20b-*` | Deleted |
| HTTPRoutes `wb-aim-*` | Deleted |

**Retained:** `AIMModel/gemma-4-31b-local`, `Service/gemma-4-31b-local` (LLM bridge for telecom).

---

## 9. Deploy command

```bash
bash scripts/09-telecom-assistant.sh
```

Optional env:

```bash
FRONTEND_LIVEKIT_URL=ws://localhost:7880 \
TELECOM_NAMESPACE=telecom-assistant \
TELECOM_RELEASE=eai-telecom \
bash scripts/09-telecom-assistant.sh
```

---

## 10. Validation

```bash
# Integration (cluster APIs, no browser)
pytest tests/integration/test_telecom_assistant.py -v

# Playwright E2E (requires port-forwards)
E2E_TELECOM=1 pytest tests/e2e/test_telecom_assistant.py -v
```

---

## 11. Known limitations on gfx1151

| Limitation | Mitigation |
|------------|------------|
| Single GPU shared host + k8s | LLM on host GPU; STT/TTS on CPU — no contention |
| No gfx1151 AIM images for Qwen STT/TTS | CPU faster-whisper + Kokoro-82M in `services/` |
| kgateway HTTPRoute templates | Port-forward phase 1; custom Envoy routes phase 2 |
| Disk ~80% used | Whisper/Kokoro HF pulls are smaller than Qwen 1.7B weights |
| LibreDesk ticket API | Seeded by postgres-dump-restore Job ([DEPLOYMENT.md](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/docs/DEPLOYMENT.md#postgres-data-migration)) |
