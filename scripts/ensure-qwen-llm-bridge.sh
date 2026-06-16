#!/usr/bin/env bash
# Wire qwen-llm to a Ready Qwen AIM predictor (any namespace).
# Matches Workbench catalog Deploy (demo/wb-aim-*) and scripts/10/11 alike.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

BRIDGE_MANIFEST="${EAI_ROOT}/manifests/telecom-assistant/qwen-llm-bridge.yaml"
NAMESPACE="${QWEN_LLM_NAMESPACE:-default}"
SERVICE="${QWEN_LLM_SERVICE:-qwen-llm}"
# AIMClusterModel name / pod label aim.eai.amd.com/model (Workbench + scripts/11).
QWEN_AIM_MODEL="${QWEN_AIM_MODEL:-qwen-qwen3-6-35b-moe}"
PREDICTOR_PORT="${QWEN_PREDICTOR_PORT:-8000}"
WAIT_SECS="${QWEN_BRIDGE_WAIT:-180}"

kubectl apply -f "$BRIDGE_MANIFEST"
# Drop legacy selector so Endpoints are authoritative (cross-namespace Workbench deploys).
kubectl patch service "$SERVICE" -n "$NAMESPACE" --type json \
  -p='[{"op":"remove","path":"/spec/selector"}]' 2>/dev/null || true
# Remove deprecated 27B-only service name if present.
kubectl delete service qwen3-6-27b-llm -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

find_ready_predictor() {
  kubectl get pods -A \
    -l "aim.eai.amd.com/model=${QWEN_AIM_MODEL},component=predictor" \
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

find_hybrid_predictor() {
  local hybrid_app="${QWEN_HYBRID_APP:-qwen3-6-35b-moe-vllm}"
  kubectl get pods -n "$NAMESPACE" -l app="$hybrid_app" \
    --field-selector=status.phase=Running \
    -o json 2>/dev/null | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
ready = [
    p for p in items
    if p.get('status', {}).get('podIP')
    and any(cs.get('ready') for cs in (p.get('status', {}).get('containerStatuses') or []))
]
if not ready:
    sys.exit(1)
p = ready[0]
print('|'.join([p['metadata']['namespace'], p['metadata']['name'], p['status']['podIP'], '${hybrid_app}']))
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

resolve_backend() {
  local line=""
  if line="$(find_ready_predictor 2>/dev/null)"; then
    echo "$line"
    return 0
  fi
  if [[ "${QWEN_USE_HYBRID_VLLM:-0}" == "1" ]] || line="$(find_hybrid_predictor 2>/dev/null)"; then
    if [[ -z "$line" ]]; then
      kubectl scale deployment "${QWEN_HYBRID_APP:-qwen3-6-35b-moe-vllm}" -n "$NAMESPACE" --replicas=1 2>/dev/null || true
      kubectl rollout status deployment/"${QWEN_HYBRID_APP:-qwen3-6-35b-moe-vllm}" -n "$NAMESPACE" --timeout=900s 2>/dev/null || true
      line="$(find_hybrid_predictor)"
    fi
    echo "$line"
    return 0
  fi
  return 1
}

echo "Discovering Ready Qwen predictor (model=${QWEN_AIM_MODEL})..."
deadline=$((SECONDS + WAIT_SECS))
line=""
while true; do
  if line="$(resolve_backend 2>/dev/null)"; then
    break
  fi
  if (( SECONDS >= deadline )); then
    echo "WARN: No Ready Qwen predictor after ${WAIT_SECS}s."
    echo "  Deploy Qwen from AI Workbench catalog (Deploy), then re-run this script."
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
