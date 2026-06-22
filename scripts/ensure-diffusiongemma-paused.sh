#!/usr/bin/env bash
# Ensure DiffusionGemma AIM inference is fully stopped before Phi-4 / other GPU workloads.
#
# Scales all DiffusionGemma InferenceService predictors to 0 replicas and patches
# AIMService replicas to 0 so the operator does not scale predictors back to 1.
#
# Usage:
#   bash scripts/ensure-diffusiongemma-paused.sh [namespace...]
#   bash scripts/ensure-diffusiongemma-paused.sh demo default
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

DG_MODEL_LABEL="${DG_AIM_MODEL:-google-diffusiongemma-26b}"
DG_MODEL_NAMES="${DG_CATALOG_MODELS:-google-diffusiongemma-26b diffusiongemma-26b}"
NAMESPACES=("$@")
if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
  NAMESPACES=(demo default)
fi

echo "=== ensure-diffusiongemma-paused (model=${DG_MODEL_LABEL}) ==="

if ! kubectl cluster-info &>/dev/null; then
  echo "WARN: kubectl cluster not reachable — skip pause (run again after cluster start)."
  exit 0
fi

pause_isvc() {
  local ns="$1" isvc="$2"
  echo "  Scaling InferenceService/${ns}/${isvc} → 0 replicas..."
  kubectl patch inferenceservice "$isvc" -n "$ns" --type=json \
    -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0},{"op":"replace","path":"/spec/predictor/maxReplicas","value":0}]' \
    2>/dev/null || true
}

pause_aimservice() {
  local ns="$1" name="$2"
  echo "  Patching AIMService/${ns}/${name} replicas → 0..."
  kubectl patch aimservice "$name" -n "$ns" --type=json \
    -p='[{"op":"replace","path":"/spec/replicas","value":0}]' 2>/dev/null || true
}

for NS in "${NAMESPACES[@]}"; do
  if ! kubectl get namespace "$NS" &>/dev/null; then
    continue
  fi
  echo "--- namespace ${NS} ---"

  for isvc in $(kubectl get inferenceservice -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    model_label="$(kubectl get inferenceservice "$isvc" -n "$NS" \
      -o jsonpath='{.metadata.labels.aim\.eai\.amd\.com/model}' 2>/dev/null || true)"
    if [[ "$model_label" == "$DG_MODEL_LABEL" ]] || echo "$isvc" | grep -qi diffusiongemma; then
      pause_isvc "$NS" "$isvc"
    fi
  done

  for svc in $(kubectl get aimservice -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    spec_model="$(kubectl get aimservice "$svc" -n "$NS" \
      -o jsonpath='{.spec.model.name}' 2>/dev/null || true)"
    for dg_name in $DG_MODEL_NAMES; do
      if [[ "$spec_model" == "$dg_name" ]] || echo "$svc" | grep -qi diffusiongemma; then
        pause_aimservice "$NS" "$svc"
        break
      fi
    done
  done
done

echo ""
echo "Waiting for DiffusionGemma predictor pods to terminate..."
deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
  running="$(kubectl get pods -A \
    -l "aim.eai.amd.com/model=${DG_MODEL_LABEL},component=predictor" \
    --field-selector=status.phase=Running \
    -o name 2>/dev/null | wc -l)"
  if [[ "$running" -eq 0 ]]; then
    echo "OK: no Running DiffusionGemma predictor pods."
    exit 0
  fi
  echo "  ${running} predictor pod(s) still Running..."
  sleep 5
done

echo "WARN: DiffusionGemma predictor pods may still be running after 120s:"
kubectl get pods -A -l "aim.eai.amd.com/model=${DG_MODEL_LABEL},component=predictor" 2>/dev/null || true
exit 1
