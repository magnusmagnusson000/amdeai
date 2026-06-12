# Call flow: Telecom Assistant (gfx1151 adaptation)

**Script:** `scripts/09-telecom-assistant.sh`  
**Namespace:** `telecom-assistant`  
**Release:** `eai-telecom`  
**Adaptation guide:** [`docs/TELECOM_ASSISTANT_GFX1151_ADAPTATION.md`](../TELECOM_ASSISTANT_GFX1151_ADAPTATION.md)

## Overview

```
Browser → Frontend (:3000, /livekit WS proxy) → LiveKit (WebRTC)
                ↓
         VoiceAgent → STT (telecom-stt, CPU) → LLM (Qwen3.6-27B AIM) → TTS (telecom-tts, CPU)
                ↓              ↓                         ↓
            BSSGateway    ChromaDB + Embedding      LibreDesk + Redis
```

On gfx1151 the LLM leg uses managed **AIMService `qwen3-6-27b`** (vLLM on gfx1151), reached via stable Service **`qwen3-6-27b-llm`** in namespace `default`. STT and TTS are CPU-only services in `services/`.

## Prerequisites

```bash
# Qwen3.6-27B AIM (LLM backend)
kubectl get aimservice qwen3-6-27b -n default
kubectl get svc qwen3-6-27b-llm -n default
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl:8.18.0 -n telecom-assistant -- \
  curl -sf http://qwen3-6-27b-llm.default.svc.cluster.local/v1/models

# Cluster access
kubectl cluster-info
```

Deploy Qwen AIM first if missing: `bash scripts/10-qwen3-6-27b.sh`

## Deploy

```bash
bash scripts/09-telecom-assistant.sh
```

## Access (port-forward)

```bash
kubectl port-forward --address 0.0.0.0 svc/aimsb-telecom-assistant-eai-telecom-frontend 3000:3000 -n telecom-assistant
```

Open `http://localhost:3000`. LiveKit signaling uses `ws://<host>:3000/livekit` (proxied by the frontend).

## Validate

```bash
pytest tests/integration/test_telecom_assistant.py -v
E2E_TELECOM=1 pytest tests/e2e/test_telecom_assistant.py -v
```

## Speech (manual)

See [`docs/TELECOM_ASSISTANT_SPEECH_TESTING.md`](../TELECOM_ASSISTANT_SPEECH_TESTING.md).

## Teardown

```bash
kubectl delete -f manifests/telecom-assistant/stt-deployment.yaml -n telecom-assistant
kubectl delete -f manifests/telecom-assistant/tts-deployment.yaml -n telecom-assistant
kubectl delete -f manifests/telecom-assistant/qwen-llm-bridge.yaml
helm template eai-telecom ~/eai-build/solution-blueprints/solution-blueprints/telecom-assistant \
  -f manifests/telecom-assistant/values-eai-local.yaml \
  -n telecom-assistant | kubectl delete -f - -n telecom-assistant
kubectl delete namespace telecom-assistant
```

Qwen AIM (`AIMService/qwen3-6-27b`) is cluster-scoped in `default`; remove separately if no longer needed.
