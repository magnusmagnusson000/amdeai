# Call flow: Telecom Assistant (gfx1151 adaptation)

**Script:** `scripts/09-telecom-assistant.sh`  
**Namespace:** `telecom-assistant`  
**Release:** `eai-telecom`  
**Adaptation guide:** [`docs/TELECOM_ASSISTANT_GFX1151_ADAPTATION.md`](../TELECOM_ASSISTANT_GFX1151_ADAPTATION.md)

## Overview

```
Browser → Frontend (:3000, /livekit WS proxy) → LiveKit (WebRTC)
                ↓
         VoiceAgent → STT (telecom-stt, CPU) → LLM (DiffusionGemma AIM) → TTS (telecom-tts, CPU)
                ↓              ↓                         ↓
            BSSGateway    ChromaDB + Embedding      LibreDesk + Redis
```

On gfx1151 the LLM leg uses **google/diffusiongemma-26B-A4B-it** from the AI Workbench catalog (Deploy), reached via stable Service **`diffusiongemma-llm`** in namespace `default`. [`scripts/ensure-diffusiongemma-llm-bridge.sh`](../../scripts/ensure-diffusiongemma-llm-bridge.sh) binds that Service to whichever AIM predictor pod is Ready (label `aim.eai.amd.com/model=google-diffusiongemma-26b`). STT and TTS are CPU-only services in `services/`.

A host-side runtime monitor ([`scripts/monitor-diffusiongemma-runtime.sh`](../../scripts/monitor-diffusiongemma-runtime.sh)) watches memory PSI, KFD stall signatures, and predictor health during telecom sessions.

## Prerequisites

Full playbook: [`docs/AIM_CATALOG_MODEL_DEPLOY_GFX1151.md`](../AIM_CATALOG_MODEL_DEPLOY_GFX1151.md)

DiffusionGemma deep dive: [`docs/DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md`](../DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md)

```bash
# 1. Catalog + Workbench Deploy (or scripts/12-diffusiongemma-26b.sh)
CATALOG_ONLY=1 bash scripts/12-diffusiongemma-26b.sh
# UI: /demo/models/aim-catalog → Deploy DiffusionGemma → Confirm
bash scripts/ensure-diffusiongemma-profile-mount.sh demo
bash scripts/fix-aim-httproute-gateway.sh demo
kubectl get aimservice -n demo    # Running

# 2. Tool calling + bridge → Ready predictor
bash scripts/ensure-diffusiongemma-tool-calling.sh demo
bash scripts/ensure-diffusiongemma-llm-bridge.sh
kubectl get endpoints diffusiongemma-llm -n default

kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl:8.18.0 -n telecom-assistant -- \
  curl -sf http://diffusiongemma-llm.default.svc.cluster.local/v1/models

# Cluster access
kubectl cluster-info
```

Alternative scripted AIM: `bash scripts/12-diffusiongemma-26b.sh`

Optional Qwen fallback bridge (not used by default): [`manifests/telecom-assistant/qwen-llm-bridge.yaml`](../../manifests/telecom-assistant/qwen-llm-bridge.yaml)

## Deploy

```bash
TELECOM_SKIP_BUILD=1 bash scripts/09-telecom-assistant.sh
```

The deploy script runs `preflight-diffusiongemma-guard`, pauses non-DiffusionGemma AIM inference (single GPU), wires the bridge, starts the runtime monitor, and warms up the LLM.

## Access (port-forward)

```bash
kubectl port-forward --address 0.0.0.0 svc/aimsb-telecom-assistant-eai-telecom-frontend 3000:3000 -n telecom-assistant
```

Open `http://localhost:3000`. LiveKit signaling uses `ws://<host>:3000/livekit` (proxied by the frontend).

## Validate

```bash
pytest tests/integration/test_telecom_assistant.py -v
E2E_TELECOM=1 pytest tests/e2e/test_telecom_assistant.py -v
E2E_TELECOM=1 pytest tests/e2e/test_telecom_assistant.py::test_text_chat_milkyway_passphrase -v
```

## Speech (manual)

See [`docs/TELECOM_ASSISTANT_SPEECH_TESTING.md`](../TELECOM_ASSISTANT_SPEECH_TESTING.md).

## Teardown

```bash
kill $(cat ~/amdeai-monitor/dg-telecom/monitor.pid) 2>/dev/null || true
kubectl delete -f manifests/telecom-assistant/stt-deployment.yaml -n telecom-assistant
kubectl delete -f manifests/telecom-assistant/tts-deployment.yaml -n telecom-assistant
kubectl delete -f manifests/telecom-assistant/diffusiongemma-llm-bridge.yaml
helm template eai-telecom ~/eai-build/solution-blueprints/solution-blueprints/telecom-assistant \
  -f manifests/telecom-assistant/values-eai-local.yaml \
  -n telecom-assistant | kubectl delete -f - -n telecom-assistant
kubectl delete namespace telecom-assistant
```

DiffusionGemma AIM remains cluster-scoped in `demo`; pause with `bash scripts/pause-aim-inference.sh demo diffusiongemma` when freeing the GPU.
