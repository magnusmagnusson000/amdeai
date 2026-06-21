#!/usr/bin/env bash
# Enable vLLM Gemma4 tool calling for DiffusionGemma (telecom agent uses tool_choice=auto).
# Patches profile ConfigMap + AIMClusterProfile, then restarts Ready predictors.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

NS="${1:-demo}"
DG_AIM_MODEL="${DG_AIM_MODEL:-google-diffusiongemma-26b}"
export REGISTRY_HOST="${LOCAL_REGISTRY:-$(registry_host)}"

PROFILE_CM="${EAI_ROOT}/manifests/aim/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml"
PROFILE_CR="${EAI_ROOT}/manifests/aim/diffusiongemma-26b/aim-clusterprofile.yaml"
PROFILE_MOUNT_SCRIPT="${SCRIPT_DIR}/ensure-diffusiongemma-profile-mount.sh"
LLM_MODEL="${LLM_MODEL:-google/diffusiongemma-26B-A4B-it}"
SPIKE_TIMEOUT="${DG_TOOL_SPIKE_TIMEOUT:-180}"

echo "=== ensure-diffusiongemma-tool-calling (namespace=${NS}, model=${DG_AIM_MODEL}) ==="
kubectl apply -f "$PROFILE_CM"
if [[ "$NS" != "demo" ]]; then
  cm_name="$(basename "$PROFILE_CM" | sed 's/-profile-configmap.yaml//')"
  kubectl get configmap "${cm_name}-profile" -n demo -o yaml 2>/dev/null \
    | sed "s/namespace: demo/namespace: ${NS}/" | kubectl apply -f - || true
fi
envsubst '${REGISTRY_HOST}' < "$PROFILE_CR" | kubectl apply -f -

for pod in $(kubectl get pods -A \
  -l "aim.eai.amd.com/model=${DG_AIM_MODEL},component=predictor" \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  pns="${pod%%/*}"
  pname="${pod#*/}"
  echo "Restarting predictor ${pns}/${pname} to pick up tool-calling args..."
  kubectl delete pod -n "$pns" "$pname" --wait=false
done

bash "$PROFILE_MOUNT_SCRIPT" "$NS" 2>/dev/null || true

echo "Waiting for a Ready DiffusionGemma predictor..."
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
  if kubectl get pods -A \
    -l "aim.eai.amd.com/model=${DG_AIM_MODEL},component=predictor" \
    -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null \
    | grep -q .; then
    echo "DiffusionGemma predictor Ready with tool-calling profile."
    bash "$SCRIPT_DIR/ensure-diffusiongemma-llm-bridge.sh" || true

    echo "--- Tool-calling spike (enable_thinking=true) ---"
    if kubectl run dg-tool-spike --rm -i --restart=Never --image=curlimages/curl:8.18.0 \
      -n "${NS}" -- \
      sh -c "curl -sf --max-time ${SPIKE_TIMEOUT} -X POST http://diffusiongemma-llm.default.svc.cluster.local/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d '{\"model\":\"${LLM_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2?\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"calc\",\"description\":\"Calculator\",\"parameters\":{\"type\":\"object\",\"properties\":{\"expr\":{\"type\":\"string\"}}}}}],\"max_tokens\":30,\"temperature\":0,\"chat_template_kwargs\":{\"enable_thinking\":true}}'" \
      2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('finish_reason:', d['choices'][0]['finish_reason'])"; then
      echo "Tool-calling spike OK."
    else
      echo "WARN: tool-calling spike failed or bridge not wired yet (run ensure-diffusiongemma-llm-bridge.sh)."
    fi
    exit 0
  fi
  sleep 10
done
echo "WARN: DiffusionGemma predictor not Ready after 900s"
exit 1
