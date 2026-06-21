#!/usr/bin/env bash
# Wire diffusiongemma-llm to a Ready DiffusionGemma AIM predictor (any namespace).
# Matches Workbench catalog Deploy and scripts/12 alike.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

BRIDGE_MANIFEST="${EAI_ROOT}/manifests/telecom-assistant/diffusiongemma-llm-bridge.yaml"
NAMESPACE="${DG_LLM_NAMESPACE:-default}"
SERVICE="${DG_LLM_SERVICE:-diffusiongemma-llm}"
DG_AIM_MODEL="${DG_AIM_MODEL:-google-diffusiongemma-26b}"
PREDICTOR_PORT="${DG_PREDICTOR_PORT:-8000}"
WAIT_SECS="${DG_BRIDGE_WAIT:-180}"

kubectl apply -f "$BRIDGE_MANIFEST"
kubectl patch service "$SERVICE" -n "$NAMESPACE" --type json \
  -p='[{"op":"remove","path":"/spec/selector"}]' 2>/dev/null || true

find_ready_predictor() {
  kubectl get pods -A \
    -l "aim.eai.amd.com/model=${DG_AIM_MODEL},component=predictor" \
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

echo "Discovering Ready DiffusionGemma predictor (model=${DG_AIM_MODEL})..."
deadline=$((SECONDS + WAIT_SECS))
line=""
while true; do
  if line="$(find_ready_predictor 2>/dev/null)"; then
    break
  fi
  if (( SECONDS >= deadline )); then
    echo "WARN: No Ready DiffusionGemma predictor after ${WAIT_SECS}s."
    echo "  Deploy DiffusionGemma from AI Workbench catalog or scripts/12, then re-run."
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
