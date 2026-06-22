#!/usr/bin/env bash
# Wire phi-4-llm to a Ready Phi-4 14B AIM predictor (any namespace).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

BRIDGE_MANIFEST="${EAI_ROOT}/manifests/telecom-assistant/phi-4-llm-bridge.yaml"
NAMESPACE="${PHI_LLM_NAMESPACE:-default}"
SERVICE="${PHI_LLM_SERVICE:-phi-4-llm}"
PHI_AIM_MODEL="${PHI_AIM_MODEL:-microsoft-phi-4-14b}"
PREDICTOR_PORT="${PHI_PREDICTOR_PORT:-8000}"
WAIT_SECS="${PHI_BRIDGE_WAIT:-180}"

kubectl apply -f "$BRIDGE_MANIFEST"
kubectl patch service "$SERVICE" -n "$NAMESPACE" --type json \
  -p='[{"op":"remove","path":"/spec/selector"}]' 2>/dev/null || true

find_ready_predictor() {
  kubectl get pods -A \
    -l "aim.eai.amd.com/model=${PHI_AIM_MODEL},component=predictor" \
    -o json 2>/dev/null | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
ready = [
    p for p in items
    if p.get('status', {}).get('podIP')
    and any(cs.get('ready') for cs in (p.get('status', {}).get('containerStatuses') or []))
]
ready.sort(key=lambda p: p['metadata']['creationTimestamp'], reverse=True)
if not ready:
    sys.exit(1)
p = ready[0]
labels = p['metadata'].get('labels') or {}
print('|'.join([
    p['metadata']['namespace'],
    p['metadata']['name'],
    p['status']['podIP'],
    labels.get('aim.eai.amd.com/service.name', ''),
]))
"
}

apply_bridge_endpoints() {
  local pod_ip="$1"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Endpoints
metadata:
  name: ${SERVICE}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/component: telecom-llm-bridge
subsets:
  - addresses:
      - ip: ${pod_ip}
    ports:
      - name: http
        port: ${PREDICTOR_PORT}
EOF
}

bridge_target_ip() {
  kubectl get endpoints "$SERVICE" -n "$NAMESPACE" \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true
}

echo "Discovering Ready Phi-4 predictor (model=${PHI_AIM_MODEL})..."
deadline=$((SECONDS + WAIT_SECS))
line=""
while true; do
  if line="$(find_ready_predictor 2>/dev/null)"; then
    break
  fi
  if (( SECONDS >= deadline )); then
    echo "WARN: No Ready Phi-4 predictor after ${WAIT_SECS}s."
    exit 0
  fi
  echo "  Waiting for AIM predictor..."
  sleep 5
done

IFS='|' read -r pod_ns pod_name pod_ip aim_service <<<"$line"
current_ip="$(bridge_target_ip)"

if [[ "$current_ip" == "$pod_ip" ]]; then
  echo "Bridge ${SERVICE}.${NAMESPACE} already → ${pod_ns}/${pod_name} (${aim_service})"
else
  echo "Bridge ${SERVICE}.${NAMESPACE} → ${pod_ns}/${pod_name} (${aim_service}) @ ${pod_ip}:${PREDICTOR_PORT}"
  apply_bridge_endpoints "$pod_ip"
fi

echo "LLM URL for telecom: http://${SERVICE}.${NAMESPACE}.svc.cluster.local/v1"
