# Telecom Assistant — manual speech testing guide

Automated Playwright tests cover UI, APIs, LiveKit signaling, and **text chat** via the Client Simulator. **Microphone STT and speaker TTS** require manual validation in the browser.

STT and TTS run as **CPU-only** services (`telecom-stt`, `telecom-tts`). The LLM is **Qwen3.6-27B** — deploy from the **AI Workbench catalog** (see playbook below), then start telecom.

**Model deploy playbook:** [`AIM_CATALOG_MODEL_DEPLOY_GFX1151.md`](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md)  
**Prerequisites doc:** [`TELECOM_ASSISTANT_GFX1151_ADAPTATION.md`](TELECOM_ASSISTANT_GFX1151_ADAPTATION.md)  
**Qwen-specific details:** [`QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md`](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md)

**Typical order:**

```bash
CATALOG_ONLY=1 bash scripts/10-qwen3-6-27b.sh          # catalog CRs (once)
# AI Workbench → Deploy Qwen on /demo/models/aim-catalog
bash scripts/ensure-qwen-profile-mount.sh demo
bash scripts/fix-aim-httproute-gateway.sh demo
bash scripts/ensure-qwen-llm-bridge.sh
TELECOM_SKIP_BUILD=1 bash scripts/09-telecom-assistant.sh
```

---

## Before you start

### 1. Confirm stack is up

```bash
kubectl get aimservice -n demo                    # expect Running (wb-aim-*)
kubectl get endpoints qwen3-6-27b-llm -n default
bash scripts/ensure-qwen-llm-bridge.sh            # if endpoints empty
```

Minimum for speech:

| Pod / deployment | Ready | Role |
|------------------|-------|------|
| `eai-telecom-livekit` | 1/1 | WebRTC signaling |
| `telecom-stt` | 1/1 | Speech-to-text (faster-whisper, CPU) |
| `telecom-tts` | 1/1 | Text-to-speech (Kokoro-82M, CPU) |
| `aimsb-telecom-assistant-eai-telecom-agent` | 1/1 | Voice orchestration |
| `aimsb-telecom-assistant-eai-telecom-frontend` | 1/1 | Browser UI |

Verify Qwen LLM from the cluster:

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl:8.18.0 -n telecom-assistant -- \
  curl -sf http://qwen3-6-27b-llm.default.svc.cluster.local/v1/models
```

Verify CPU speech services:

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl:8.18.0 -n telecom-assistant -- \
  sh -c 'curl -sf http://telecom-stt/v1/models && curl -sf http://telecom-tts/v1/models'
```

### 2. Port-forward (local or LAN)

**Frontend only** (LiveKit WebSocket is proxied at `/livekit` on the same port):

```bash
kubectl port-forward --address 0.0.0.0 svc/aimsb-telecom-assistant-eai-telecom-frontend 3000:3000 -n telecom-assistant
```

Open **Chrome or Edge**: `http://localhost:3000` (or `http://<node-ip>:3000` from LAN).

The API returns `serverUrl: ws://<host>:3000/livekit` automatically when `LIVEKIT_PROXY_ENABLED=1`.

Allow microphone permission when prompted.

---

## Test matrix

| ID | Feature | Input | Expected result | Pass? |
|----|---------|-------|-----------------|-------|
| S1 | Connect | Open UI | Live badge, agent greeting (TTS) | |
| S2 | STT | Speak a short question | Agent responds (text + voice) | |
| S3 | RAG | Ask about roaming/invoice | Billing KB context in answer | |
| S4 | Account | Client Simulator: `My passphrase is milkyway` | John Black account details | |
| S5 | TTS | Ask a question | Audible reply | |

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| UI error on connect | Frontend logs; `LIVEKIT_PROXY_ENABLED=1` in frontend env |
| WebSocket 101 but no audio | WebRTC/TURN (STUNner LB); ZScaler may block UDP |
| LLM timeout in agent log | `kubectl get aimservice -n demo`; `bash scripts/ensure-qwen-llm-bridge.sh`; `bash scripts/warmup-llm.sh` |
| STT/TTS 422 | Agent `STT_BASE_URL` / `TTS_BASE_URL` → `http://telecom-stt/v1`, `http://telecom-tts/v1` |
| Slow first reply | Normal for cold vLLM; warmup CronJob + frontend warmup mitigate |

Agent logs:

```bash
kubectl logs -f deploy/aimsb-telecom-assistant-eai-telecom-agent -n telecom-assistant -c agent
```

Qwen predictor:

```bash
kubectl logs -n demo -l component=predictor --tail=50
```

CPU speech services can stay running alongside the Qwen GPU predictor; they do not use the GPU.
