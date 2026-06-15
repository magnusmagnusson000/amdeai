# Telecom Assistant — gfx1151 / Bloom adaptation guide

This document records every change required to run the [AMD Telecom Assistant blueprint](https://github.com/amd-enterprise-ai/solution-blueprints/tree/main/solution-blueprints/telecom-assistant) on the gfx1151 Bloom lab cluster (Asus Z13, Radeon 8060S, RKE2).

**Related docs**

| Topic | Location |
|-------|----------|
| Deploy script | [`scripts/09-telecom-assistant.sh`](../scripts/09-telecom-assistant.sh) |
| Helm overrides | [`manifests/telecom-assistant/values-eai-local.yaml`](../manifests/telecom-assistant/values-eai-local.yaml) |
| Call flow | [`docs/call-flows/09-telecom-assistant.md`](call-flows/09-telecom-assistant.md) |
| Speech manual tests | [`docs/TELECOM_ASSISTANT_SPEECH_TESTING.md`](TELECOM_ASSISTANT_SPEECH_TESTING.md) |
| **AIM catalog model deploy (playbook)** | [`docs/AIM_CATALOG_MODEL_DEPLOY_GFX1151.md`](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md) |
| Qwen3.6-27B AIM (LLM backend) | [`docs/QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md`](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md) |
| Blueprint upstream deploy | [solution-blueprints `docs/DEPLOYMENT.md`](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/docs/DEPLOYMENT.md) |

---

## 1. Repository layout

| Path | Purpose |
|------|---------|
| `~/eai-build/solution-blueprints` | Upstream blueprint (cloned, not forked) |
| `manifests/telecom-assistant/values-eai-local.yaml` | gfx1151-specific Helm overrides (tracked in amdeai) |
| `manifests/telecom-assistant/qwen-llm-bridge.yaml` | Stable ClusterIP + dynamic Endpoints → Ready Qwen3.6-27B AIM predictor |
| `telecom-assistant` namespace | Isolated deploy target |

---

## 2. LLM: GPT OSS 120B → Qwen3.6-27B (managed AIMService)

### Upstream default

The parent chart deploys sub-chart `llm` → image `amdenterpriseai/aim-openai-gpt-oss-120b:0.10.0` with **512 GiB** ephemeral storage.

### gfx1151 change

| Setting | Value | Reason |
|---------|-------|--------|
| `llm.existingService` | `http://qwen3-6-27b-llm.default.svc.cluster.local` | Skip in-cluster GPT OSS pod; use managed **Qwen/Qwen3.6-27B** vLLM |
| `mainServices.agent.env.LLM_MODEL` | `Qwen/Qwen3.6-27B` | OpenAI model id from vLLM `--served-model-name` |
| `mainServices.agent.env.LLM_API_KEY` | `no-key-required` | No auth on cluster endpoint |

The chart sets agent `LLM_BASE_URL` to `{existingService}/v1` via `aimchart-llm.url`.

**Prerequisite:** Deploy **Qwen/Qwen3.6-27B** from the **AI Workbench model catalog** (Deploy button), wait until the AIMService predictor is Ready. Alternatively use `bash scripts/10-qwen3-6-27b.sh` for the scripted `default/qwen3-6-27b` AIMService.

### Additional changes for Qwen AIM (beyond Helm values)

1. **Stable bridge Service** — [`manifests/telecom-assistant/qwen-llm-bridge.yaml`](../manifests/telecom-assistant/qwen-llm-bridge.yaml) + [`scripts/ensure-qwen-llm-bridge.sh`](../scripts/ensure-qwen-llm-bridge.sh)  
   Workbench creates AIMServices like `demo/wb-aim-*` with dynamic names. Telecom keeps a **fixed DNS name** (`qwen3-6-27b-llm.default.svc.cluster.local`) and the ensure script writes **Endpoints** to whichever predictor pod is Ready, matched cluster-wide by catalog model label `aim.eai.amd.com/model=qwen-qwen3-6-27b`. Newest Ready predictor wins (your latest Workbench Deploy). Set `QWEN_USE_HYBRID_VLLM=1` only for the legacy hybrid `qwen3-6-27b-vllm` Deployment.

2. **Agent patches** — [`services/telecom-agent/agent.py`](../services/telecom-agent/agent.py) mounted via ConfigMap ([`scripts/patch-telecom-agent.sh`](../scripts/patch-telecom-agent.sh)):
   - LLM read timeout **120s** (Qwen first-token latency on 27B)
   - Worker **prewarm** calls `/v1/chat/completions` at startup
   - Recoverable error handler (no session kill on transient LLM errors)

3. **Frontend warmup + LiveKit WS proxy** — [`services/telecom-frontend/`](../services/telecom-frontend/):
   - `LLM_WARMUP_URL` → bridge Service (page-load vLLM warmup)
   - `LIVEKIT_PROXY_ENABLED=1` — WebSocket proxied at `/livekit` on port 3000 (LAN-friendly single port-forward)

4. **LLM warmup CronJob** — [`manifests/telecom-assistant/llm-warmup-cronjob.yaml`](../manifests/telecom-assistant/llm-warmup-cronjob.yaml) hits the bridge every 2 minutes.

5. **GPU allocation** — Qwen3.6-27B uses the single gfx1151 GPU inside the cluster (vLLM predictor pod). CPU STT/TTS do **not** use the GPU, so voice + LLM can run concurrently without stopping other services.

6. **Reasoning model** — Qwen3.6-27B uses `--reasoning-parser qwen3`. Responses may include `reasoning` fields; agent timeouts were increased accordingly. E2E text-chat timeout is **240s**.

---

## 3. Embedding: gfx942 → CPU Infinity

| Setting | Value | Reason |
|---------|-------|--------|
| `embedding.image` | `michaelf34/infinity:latest` | CPU build; gfx942 ROCm tag fails on RDNA3.5 |
| `embedding.gpus` | `0` | Avoid claiming GPU from Qwen predictor |

---

## 4. STT / TTS: CPU-only speech services

Upstream Qwen GPU sub-charts are replaced with faster-whisper + Kokoro-82M in [`services/stt-service/`](../services/stt-service/) and [`services/tts-service/`](../services/tts-service/).

| Setting | Value |
|---------|-------|
| `stt.existingService` | `telecom-stt` |
| `stt.replicas` | `0` |
| `tts.existingService` | `telecom-tts` |
| `tts.replicas` | `0` |

No GPU handoff required — Qwen LLM and CPU speech coexist.

---

## 5. Storage, Gateway, STUNner, infra images

Unchanged from prior gfx1151 adaptation: `mlstorage`, port-forward phase 1, STUNner enabled (`stunner.enabled: true`). See [`call-flows/09-telecom-assistant.md`](call-flows/09-telecom-assistant.md) for port-forward and WebRTC notes.

### Docker Hub rate limits

| Component | Workaround |
|-----------|------------|
| `libredesk/libredesk:v1.0.3` | Use `ghcr.io/abhinavxd/libredesk:v1.0.3-amd64` in `infraServices.libredesk.image` |
| `amdenterpriseai/...-bssgateway` | Build locally from [`services/telecom-bssgateway/`](../services/telecom-bssgateway/) (reuses `telecom-stt-service:local` base) |
| `amdenterpriseai/...-agent` | Build from upstream `docker/agent.Dockerfile` (GHCR `uv` base); tag `telecom-agent:local`, `imagePullPolicy: Never` |
| Global pulls | `imagePullPolicy: IfNotPresent` in `values-eai-local.yaml` after importing images into RKE2 containerd |

`scripts/09-telecom-assistant.sh` builds and imports bssgateway by default (`BUILD_BSSGATEWAY=1`). Set `BUILD_TELECOM_AGENT=1` on first deploy or after upstream agent changes (slow build; uses GHCR not Docker Hub).

---

## 6. Deploy command (demo workflow)

```bash
# 1. AI Workbench → model catalog → Qwen/Qwen3.6-27B → Deploy → wait until Running

# 2. Wire bridge to that predictor (auto-run by step 3; can re-run anytime)
bash scripts/ensure-qwen-llm-bridge.sh
kubectl get endpoints qwen3-6-27b-llm -n default

# 3. Deploy telecom stack (skip rebuilds if images already in containerd)
TELECOM_SKIP_BUILD=1 bash scripts/09-telecom-assistant.sh
```

Step 3 waits up to 5 minutes for a Ready Qwen predictor if Workbench is still starting.

---

## 7. Validation

```bash
pytest tests/integration/test_telecom_assistant.py -v
E2E_TELECOM=1 pytest tests/e2e/test_telecom_assistant.py -v
```

---

## 8. Known limitations on gfx1151

| Limitation | Mitigation |
|------------|------------|
| Single GPU | Qwen vLLM predictor owns GPU; STT/TTS on CPU |
| Qwen STT/TTS upstream images | CPU faster-whisper + Kokoro in `services/` |
| STUNner LoadBalancer pending | MetalLB pool may be exhausted; use LiveKit WS proxy on :3000; TURN may need shared-IP fix |
| Qwen latency | Agent 120s LLM timeout; frontend + CronJob warmup |
