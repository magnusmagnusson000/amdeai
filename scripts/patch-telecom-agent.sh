#!/usr/bin/env bash
# Mount patched agent.py over upstream image (avoids a second 8GB local image).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TELECOM_NAMESPACE="${TELECOM_NAMESPACE:-telecom-assistant}"
TELECOM_RELEASE="${TELECOM_RELEASE:-eai-telecom}"
AGENT_PY="${EAI_ROOT}/services/telecom-agent/agent.py"
DEPLOY="aimsb-telecom-assistant-${TELECOM_RELEASE}-agent"

if [[ ! -f "$AGENT_PY" ]]; then
  echo "ERROR: patched agent.py not found: $AGENT_PY"
  exit 1
fi

kubectl create configmap telecom-agent-patch \
  --from-file=agent.py="$AGENT_PY" \
  -n "$TELECOM_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl patch deployment "$DEPLOY" -n "$TELECOM_NAMESPACE" --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "agent-patch", "configMap": {"name": "telecom-agent-patch"}}},
  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "agent-patch", "mountPath": "/app/agent.py", "subPath": "agent.py"}}
]' 2>/dev/null || kubectl patch deployment "$DEPLOY" -n "$TELECOM_NAMESPACE" --type=strategic -p "$(cat <<'EOF'
spec:
  template:
    spec:
      volumes:
        - name: agent-patch
          configMap:
            name: telecom-agent-patch
      containers:
        - name: agent
          volumeMounts:
            - name: agent-patch
              mountPath: /app/agent.py
              subPath: agent.py
EOF
)"

echo "Patched $DEPLOY with telecom-agent-patch ConfigMap"
