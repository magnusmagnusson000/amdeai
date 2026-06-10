#!/usr/bin/env bash
# Remove STT/TTS init waits on single-GPU gfx1151 — both cannot be Ready simultaneously.
set -euo pipefail

NAMESPACE="${TELECOM_NAMESPACE:-telecom-assistant}"
DEPLOY="${TELECOM_AGENT_DEPLOY:-aimsb-telecom-assistant-eai-telecom-agent}"

echo "Patching ${DEPLOY}: drop wait-for-qwen-stt / wait-for-qwen-tts init containers..."
kubectl get deployment "$DEPLOY" -n "$NAMESPACE" -o json | python3 -c '
import json, sys
doc = json.load(sys.stdin)
skip = {"wait-for-qwen-stt", "wait-for-qwen-tts"}
containers = doc["spec"]["template"]["spec"].get("initContainers") or []
doc["spec"]["template"]["spec"]["initContainers"] = [
    c for c in containers if c.get("name") not in skip
]
json.dump(doc, sys.stdout)
' | kubectl apply -f -
echo "Agent init patch applied."
