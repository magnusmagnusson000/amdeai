# Telecom Assistant — manual speech testing guide

Automated Playwright tests cover UI, APIs, LiveKit signaling, and **text chat** via the Client Simulator. **Microphone STT and speaker TTS** require manual validation in the browser.

STT and TTS run as **CPU-only** services (`telecom-stt`, `telecom-tts`) and do not compete with host Gemma for the GPU.

**Prerequisites doc:** [`TELECOM_ASSISTANT_GFX1151_ADAPTATION.md`](TELECOM_ASSISTANT_GFX1151_ADAPTATION.md)  
**Deploy:** `bash scripts/09-telecom-assistant.sh`

---

## Before you start

### 1. Confirm stack is up

```bash
kubectl get pods -n telecom-assistant
```

Minimum for speech:

| Pod / deployment | Ready | Role |
|------------------|-------|------|
| `eai-telecom-livekit` | 1/1 | WebRTC signaling |
| `telecom-stt` | 1/1 | Speech-to-text (faster-whisper, CPU) |
| `telecom-tts` | 1/1 | Text-to-speech (Kokoro-82M, CPU) |
| `aimsb-telecom-assistant-eai-telecom-agent` | 1/1 | Voice orchestration |
| `aimsb-telecom-assistant-eai-telecom-frontend` | 1/1 | Browser UI |

LLM (Gemma) runs on the **host GPU**, concurrently with CPU speech:

```bash
curl -sf http://localhost:8081/health
```

Verify speech services respond inside the cluster:

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl:8.18.0 -n telecom-assistant -- \
  sh -c 'curl -sf http://telecom-stt/v1/models && curl -sf http://telecom-tts/v1/models'
```

First startup may take several minutes while Whisper and Kokoro models download.

### 2. Port-forwards

```bash
kubectl port-forward svc/aimsb-telecom-assistant-eai-telecom-frontend 3000:3000 -n telecom-assistant
kubectl port-forward svc/eai-telecom-livekit 7880:7880 -n telecom-assistant
```

Open **Chrome or Edge** (best WebRTC support): `http://localhost:3000`

Allow microphone permission when prompted.

---

## Test matrix

| ID | Feature | Input | Expected result | Pass? |
|----|---------|-------|-----------------|-------|
| S1 | Live connection | Open UI | Header shows **Live** badge; no error screen | |
| S2 | Mic publish | Speak after page loads | **Listening** badge; no immediate disconnect | |
| S3 | STT passphrase `milkyway` | Say clearly: *"My passphrase is milkyway"* | Agent responds; customer name **John Black** appears in header | |
| S4 | Plan detection | Continue conversation | Plan badge shows **Regular** / Essential Connect context | |
| S5 | STT passphrase `mars` | New call; say *"mars"* | Customer **Max White**; premium plan context | |
| S6 | BSS balance query | Ask: *"What is my account balance?"* | Agent cites balance (~$125.50 for John / ~$165.50 for Max) | |
| S7 | RAG billing docs | Ask: *"What are my roaming charges?"* | Answer references billing knowledge base (not hallucinated only) | |
| S8 | TTS response | Ask any question | Hear synthesized voice reply (British English via Kokoro) | |
| S9 | Support ticket | Ask: *"I need to open a support ticket about my bill"* | Agent confirms ticket; check LibreDesk (optional) | |
| S10 | End call | Click **End call** | Call ends; can start new **Call** | |
| S11 | Mute | Toggle microphone off | **Muted** badge; agent should not react to speech | |
| S12 | Tool history | Enable **Show tool execution history** | Panel shows `get_user_by_pass_phrase` and related tool calls | |

---

## Detailed procedures

### S1 — Live connection

1. Start port-forwards (above).
2. Open `http://localhost:3000`.
3. Wait for **Connecting...** to disappear.

**Pass:** Page shows **Teleassist** header with red **Live** badge.  
**Fail:** Error screen — check `kubectl logs -n telecom-assistant deploy/aimsb-telecom-assistant-eai-telecom-frontend` and LiveKit URL env (`ws://localhost:7880` for port-forward).

### S2 — Microphone / WebRTC media

1. Grant mic permission.
2. Speak: *"Hello, can you hear me?"*

**Pass:** **Listening** badge stays active; no disconnect within 30 s.  
**Fail:** Immediate disconnect — STUNner TURN may be unreachable; check `kubectl get svc -n telecom-assistant aimsb-telecom-assistant-eai-telecom-stunner-gw` has EXTERNAL-IP (MetalLB). For port-forward-only testing, WebRTC media may be limited; see adaptation doc phase 2.

### S3 — Voice authentication (`milkyway`)

Reference: frontend hint in Client Simulator — passphrases `milkyway` (regular) and `mars` (premium).  
Mock users: [`app/BSSGateway/main.py`](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/telecom-assistant/app/BSSGateway/main.py).

1. Start a call.
2. Say: *"My passphrase is milkyway"* or just *"milkyway"*.

**Pass:** Header shows customer name **John Black**.  
**Fail:** Check agent logs: `kubectl logs -n telecom-assistant deploy/aimsb-telecom-assistant-eai-telecom-agent -f`

Also verify STT pod: `kubectl logs -n telecom-assistant deploy/telecom-stt --tail=50`

### S4 — Plan badge

After S3, ask: *"What plan am I on?"*

**Pass:** Agent mentions **Essential Connect** or Regular plan.  
**Fail:** LLM may be down — `curl http://gemma-4-31b-local.demo.svc.cluster.local:8081/health` from a debug pod.

### S5 — Premium user (`mars`)

1. **End call**, start new call.
2. Say: *"mars"*.

**Pass:** Customer **Max White**; premium / **Apex Unlimited** context in replies.

### S6 — BSS balance

Ask: *"How much do I owe on my account?"*

**Pass:** Numeric balance matching mock data (John: **125.50 USD**, Max: **165.50 USD**).  
**Fail:** `kubectl port-forward svc/aimsb-telecom-assistant-eai-telecom-bssgateway 8001:8001 -n telecom-assistant` then `curl http://localhost:8001/users/user/milkyway`

### S7 — RAG / ChromaDB

Ask: *"Explain my last invoice"* or *"What are international roaming rates?"*

**Pass:** Agent uses retrieved billing docs (may quote policy-style text).  
**Fail:** Check embedding + chromadb pods and agent init ingested data: `kubectl logs deploy/aimsb-telecom-assistant-eai-telecom-agent -c ingest-chromadb -n telecom-assistant`

### S8 — TTS audio

Ask a short question: *"What is my current balance?"*

**Pass:** Audible spoken response within ~60 s.  
**Fail:** TTS pod not ready — `kubectl get pod -n telecom-assistant -l app=telecom-tts`; check logs for Kokoro model download errors.

### S9 — LibreDesk ticket

Ask: *"Please create a support ticket for a billing dispute."*

**Pass:** Agent verbally confirms ticket creation.  
**Optional verify:**

```bash
kubectl port-forward svc/aimsb-telecom-assistant-eai-telecom-libredesk 9000:9000 -n telecom-assistant
```

LibreDesk UI: `http://localhost:9000` (seeded admin — see chart `values.yaml` `libredesk` env).

### S10 — End / restart call

1. Click **End call** (red phone icon).
2. Click **Call**.

**Pass:** New session; conversation panel resets.

### S11 — Mute

1. During active call, click microphone to mute.

**Pass:** **Muted** badge; agent does not respond to speech until unmuted.

### S12 — Tool execution panel

1. Toggle **Show tool execution history**.
2. Complete S3 or S6.

**Pass:** Panel lists tools such as `get_user_by_pass_phrase`, `get_balance`, etc.

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| Agent `Init:0/7` stuck on STT/TTS | CPU speech pods not ready | `kubectl rollout status deploy/telecom-stt deploy/telecom-tts -n telecom-assistant` |
| `telecom-stt` CrashLoopBackOff | Whisper model download OOM | Increase memory limit or check HF cache |
| `telecom-tts` not Ready | Kokoro first-run download slow | Wait up to 10 min; check logs |
| No audio output | TTS not ready or browser blocked autoplay | Check `telecom-tts` pod; unmute tab |
| LLM errors in agent log | Gemma not running | `systemctl --user status llama-gemma-31b.service` |
| WebRTC disconnect | STUNner LB pending / wrong LIVEKIT_URL | Check MetalLB; use `ws://localhost:7880` with port-forward |
| Empty STT | Mic blocked or STT not ready | Browser permissions; `kubectl logs deploy/telecom-stt` |

---

## Restoring normal operation

```bash
systemctl --user status llama-gemma-31b.service
kubectl get pods -n telecom-assistant -l 'app in (telecom-stt, telecom-tts)'
```

CPU speech services can stay running alongside host Gemma; they do not use the GPU.
