#!/usr/bin/env bash
# Enable vLLM tool calling for Qwen3.6 (telecom agent uses tool_choice=auto).
# Patches profile ConfigMap + AIMClusterProfile, then restarts Ready Qwen predictors.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

NS="${1:-demo}"
PROFILE_CM="${EAI_ROOT}/manifests/aim/qwen3-6-27b/qwen3-6-27b-r9700-gfx1151-latency-profile-configmap.yaml"
PROFILE_CR="${EAI_ROOT}/manifests/aim/qwen3-6-27b/aim-clusterprofile.yaml"
export REGISTRY_HOST="${LOCAL_REGISTRY:-$(registry_host)}"

echo "=== ensure-qwen-tool-calling (namespace=${NS}) ==="
kubectl apply -f "$PROFILE_CM"
if [[ "$NS" != "demo" ]]; then
  kubectl get configmap qwen3-6-27b-r9700-gfx1151-latency-profile -n demo -o yaml \
    | sed "s/namespace: demo/namespace: ${NS}/" | kubectl apply -f -
fi
envsubst '${REGISTRY_HOST}' < "$PROFILE_CR" | kubectl apply -f -

for pod in $(kubectl get pods -A \
  -l "aim.eai.amd.com/model=qwen-qwen3-6-27b,component=predictor" \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  pns="${pod%%/*}"
  pname="${pod#*/}"
  echo "Restarting predictor ${pns}/${pname} to pick up tool-calling args..."
  kubectl delete pod -n "$pns" "$pname" --wait=false
done

bash "$SCRIPT_DIR/ensure-qwen-profile-mount.sh" "$NS" 2>/dev/null || true

echo "Waiting for a Ready Qwen predictor..."
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
  if kubectl get pods -A \
    -l "aim.eai.amd.com/model=qwen-qwen3-6-27b,component=predictor" \
    -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null \
    | grep -q .; then
    echo "Qwen predictor Ready with tool-calling profile."
    bash "$SCRIPT_DIR/ensure-qwen-llm-bridge.sh"
    exit 0
  fi
  sleep 10
done
echo "WARN: Qwen predictor not Ready after 900s"
exit 1
