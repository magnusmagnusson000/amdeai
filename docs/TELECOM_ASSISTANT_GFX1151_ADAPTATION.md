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
| DiffusionGemma 26B AIM (LLM backend) | [`docs/DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md`](DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md) |
| Qwen3.6 AIM (optional fallback) | [`docs/QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md`](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md) |
| Blueprint upstream deploy | [solution-blueprints `docs/DEPLOYMENT.md`](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/docs/DEPLOYMENT.md) |

---

## 1. Repository layout

| Path | Purpose |
|------|---------|
| `~/eai-build/solution-blueprints` | Upstream blueprint (cloned, not forked) |
| `manifests/telecom-assistant/values-eai-local.yaml` | gfx1151-specific Helm overrides (tracked in amdeai) |
| `manifests/telecom-assistant/diffusiongemma-llm-bridge.yaml` | Stable ClusterIP + dynamic Endpoints → Ready DiffusionGemma AIM predictor |
| `manifests/telecom-assistant/qwen-llm-bridge.yaml` | Optional Qwen fallback bridge (not used by default) |
| `telecom-assistant` namespace | Isolated deploy target |

---

## 2. LLM: GPT OSS 120B → DiffusionGemma 26B (managed AIMService)

### Upstream default

The parent chart deploys sub-chart `llm` → image `amdenterpriseai/aim-openai-gpt-oss-120b:0.10.0` with **512 GiB** ephemeral storage.

### gfx1151 change (current default)

| Setting | Value | Reason |
|---------|-------|--------|
| `llm.existingService` | `http://diffusiongemma-llm.default.svc.cluster.local` | Skip in-cluster GPT OSS pod; use managed **google/diffusiongemma-26B-A4B-it** vLLM |
| `mainServices.agent.env.LLM_MODEL` | `google/diffusiongemma-26B-A4B-it` | OpenAI model id from vLLM `--served-model-name` |
| `mainServices.agent.env.LLM_ENABLE_THINKING` | `true` | Gemma4 tool calling works best with thinking enabled |
| `mainServices.agent.env.LLM_API_KEY` | `no-key-required` | No auth on cluster endpoint |

The chart sets agent `LLM_BASE_URL` to `{existingService}/v1` via `aimchart-llm.url`.

**Prerequisite:** Deploy **google/diffusiongemma-26B-A4B-it** from the **AI Workbench model catalog** (Deploy button), wait until the AIMService predictor is Ready. Alternatively use `bash scripts/12-diffusiongemma-26b.sh`.

### Additional changes for DiffusionGemma AIM (beyond Helm values)

1. **Stable bridge Service** — [`manifests/telecom-assistant/diffusiongemma-llm-bridge.yaml`](../manifests/telecom-assistant/diffusiongemma-llm-bridge.yaml) + [`scripts/ensure-diffusiongemma-llm-bridge.sh`](../scripts/ensure-diffusiongemma-llm-bridge.sh)  
   Workbench creates AIMServices like `demo/wb-aim-*` with dynamic names. Telecom keeps a **fixed DNS name** (`diffusiongemma-llm.default.svc.cluster.local`) and the ensure script writes **Endpoints** to whichever predictor pod is Ready, matched cluster-wide by catalog model label `aim.eai.amd.com/model=google-diffusiongemma-26b`.

2. **Tool calling profile** — [`scripts/ensure-diffusiongemma-tool-calling.sh`](../scripts/ensure-diffusiongemma-tool-calling.sh) applies Gemma4 vLLM args (`enable-auto-tool-choice`, `tool-call-parser: gemma4`, `reasoning-parser: gemma4`) required by the telecom agent's function tools.

3. **Runtime safety monitor** — [`scripts/monitor-diffusiongemma-runtime.sh`](../scripts/monitor-diffusiongemma-runtime.sh) (optional systemd: [`scripts/install-diffusiongemma-monitor-service.sh`](../scripts/install-diffusiongemma-monitor-service.sh))  
   Continuous host memory PSI, KFD stall detection, and predictor `/health` hang checks. Started automatically by `09-telecom-assistant.sh`; pauses inference on trip to avoid host freeze.

4. **Agent patches** — [`services/telecom-agent/agent.py`](../services/telecom-agent/agent.py) mounted via ConfigMap ([`scripts/patch-telecom-agent.sh`](../scripts/patch-telecom-agent.sh)):
   - LLM read timeout **120s**
   - Worker **prewarm** calls `/v1/chat/completions` at startup (background thread; does not block LiveKit init)
   - `AgentServer(initialize_process_timeout=120, num_idle_processes=1)` — default 10s init budget is too small for Silero VAD on gfx1151
   - `mainServices.agent.resources`: **2Gi request / 4Gi limit** in [`values-eai-local.yaml`](../manifests/telecom-assistant/values-eai-local.yaml)
   - `LLM_ENABLE_THINKING` env gates `chat_template_kwargs`
   - Recoverable error handler (no session kill on transient LLM errors)

5. **Frontend warmup + LiveKit WS proxy** — [`services/telecom-frontend/`](../services/telecom-frontend/):
   - `LLM_WARMUP_URL` → `diffusiongemma-llm` bridge Service
   - `LIVEKIT_PROXY_ENABLED=1` — WebSocket proxied at `/livekit` on port 3000

6. **LLM warmup CronJob** — [`manifests/telecom-assistant/llm-warmup-cronjob.yaml`](../manifests/telecom-assistant/llm-warmup-cronjob.yaml) hits the bridge every 2 minutes.

7. **GPU allocation** — DiffusionGemma uses the single gfx1151 GPU. Deploy pauses other AIM inference (`PAUSE_INFERENCE_EXCLUDE=diffusiongemma`). CPU STT/TTS coexist without GPU handoff.

8. **E2E text-chat timeout** — **240s** for milkyway passphrase flow (`test_text_chat_milkyway_passphrase`).

### Optional Qwen fallback

To revert the LLM leg to Qwen, point `llm.existingService` at `http://qwen-llm.default.svc.cluster.local`, set `LLM_MODEL` to `Qwen/Qwen3.6-35B-A3B`, `LLM_ENABLE_THINKING=false`, and run `ensure-qwen-tool-calling.sh` + `ensure-qwen-llm-bridge.sh`. See [`qwen-llm-bridge.yaml`](../manifests/telecom-assistant/qwen-llm-bridge.yaml).

---

## 2b. LLM history: Qwen3.6 MoE (superseded default)

Previously the default LLM was **Qwen/Qwen3.6-35B-A3B** via `qwen-llm` bridge with `tool-call-parser: qwen3_coder`. Bridge manifests and scripts remain for fallback.

---

## 3. Embedding: gfx942 → CPU Infinity

| Setting | Value | Reason |
|---------|-------|--------|
| `embedding.image` | `michaelf34/infinity:latest` | CPU build; gfx942 ROCm tag fails on RDNA3.5 |
| `embedding.gpus` | `0` | Avoid claiming GPU from DiffusionGemma predictor |

---

## 4. STT / TTS: CPU-only speech services

Upstream Qwen GPU sub-charts are replaced with faster-whisper + Kokoro-82M in [`services/stt-service/`](../services/stt-service/) and [`services/tts-service/`](../services/tts-service/).

| Setting | Value |
|---------|-------|
| `stt.existingService` | `telecom-stt` |
| `stt.replicas` | `0` |
| `tts.existingService` | `telecom-tts` |
| `tts.replicas` | `0` |

No GPU handoff required — DiffusionGemma LLM and CPU speech coexist.

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
# 1. AI Workbench → model catalog → google/diffusiongemma-26B-A4B-it → Deploy → wait until Running
#    Or: bash scripts/12-diffusiongemma-26b.sh

# 2. Wire bridge + tool calling (auto-run by step 3; can re-run anytime)
bash scripts/ensure-diffusiongemma-tool-calling.sh demo
bash scripts/ensure-diffusiongemma-llm-bridge.sh
kubectl get endpoints diffusiongemma-llm -n default

# 3. Deploy telecom stack (skip rebuilds if images already in containerd)
TELECOM_SKIP_BUILD=1 bash scripts/09-telecom-assistant.sh
```

Step 3 runs preflight memory guard (relaxed to 15 GiB when DiffusionGemma is already Ready), pauses non-DG AIM inference, starts the runtime monitor, and warms up the LLM.

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
| Single GPU | DiffusionGemma vLLM predictor owns GPU; pause other AIM; STT/TTS on CPU |
| Host memory pressure during DG load | `preflight-diffusiongemma-guard` + runtime monitor; swap ≥ 8 GiB |
| Qwen STT/TTS upstream images | CPU faster-whisper + Kokoro in `services/` |
| STUNner LoadBalancer pending | MetalLB pool may be exhausted; use LiveKit WS proxy on :3000; TURN may need shared-IP fix |
| DiffusionGemma tool calling | Gemma4 parsers + `LLM_ENABLE_THINKING=true`; agent 120s LLM timeout; warmup CronJob |
