# Call flow: Telecom Assistant (gfx1151 adaptation)

**Script:** `scripts/09-telecom-assistant.sh`  
**Namespace:** `telecom-assistant`  
**Release:** `eai-telecom`  
**Adaptation guide:** [`docs/TELECOM_ASSISTANT_GFX1151_ADAPTATION.md`](../TELECOM_ASSISTANT_GFX1151_ADAPTATION.md)

## Overview

```
Browser → Frontend (:3000) → LiveKit (WebRTC)
                ↓
         VoiceAgent → STT (Qwen ASR) → LLM (Gemma 4 host :8081) → TTS (Qwen TTS)
                ↓              ↓                    ↓
            BSSGateway    ChromaDB + Embedding    LibreDesk + Redis
```

On gfx1151 the LLM leg uses the existing host `llama-server` registered as `gemma-4-31b-local` in namespace `demo` — not the upstream GPT OSS 120B AIM pod.

## Prerequisites

```bash
# Gemma 4 31B (LLM backend)
curl -sf http://localhost:8081/health
kubectl get aimmodel gemma-4-31b-local -n demo

# Cluster access
kubectl cluster-info

# Blueprint source
ls ~/eai-build/solution-blueprints/solution-blueprints/telecom-assistant/Chart.yaml
```

## Deploy

```bash
bash scripts/09-telecom-assistant.sh
```

Optional:

```bash
FRONTEND_LIVEKIT_URL=ws://localhost:7880 \
INSTALL_STUNNER=0 \
bash scripts/09-telecom-assistant.sh
```

## Access (port-forward)

```bash
kubectl port-forward svc/aimsb-telecom-assistant-eai-telecom-frontend 3000:3000 -n telecom-assistant
kubectl port-forward svc/eai-telecom-livekit 7880:7880 -n telecom-assistant
```

Open `http://localhost:3000`.

## Validate

```bash
# Cluster integration
pytest tests/integration/test_telecom_assistant.py -v

# Browser E2E (port-forwards must be running)
E2E_TELECOM=1 pytest tests/e2e/test_telecom_assistant.py -v
```

## Speech (manual)

See [`docs/TELECOM_ASSISTANT_SPEECH_TESTING.md`](../TELECOM_ASSISTANT_SPEECH_TESTING.md).

## Teardown

```bash
helm template eai-telecom ~/eai-build/solution-blueprints/solution-blueprints/telecom-assistant \
  -f manifests/telecom-assistant/values-eai-local.yaml \
  -n telecom-assistant | kubectl delete -f - -n telecom-assistant
kubectl delete namespace telecom-assistant
```

STUNner operator in `stunner-system` is cluster-scoped; remove only if no other WebRTC workloads need it:

```bash
~/eai-build/solution-blueprints/solution-blueprints/telecom-assistant/install-prerequisites.sh --uninstall
```
