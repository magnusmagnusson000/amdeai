#!/usr/bin/env bash
# Pause AIM inference (scale predictor to 0) without deleting AIMService or weights PVC.
#
# Keeps: AIMService CR, AIMArtifact, weights PVC, catalog CRs.
# Frees: GPU for another model deployment.
#
# Usage:
#   bash scripts/pause-aim-inference.sh [namespace] [aimservice-name]
#   bash scripts/pause-aim-inference.sh demo wb-aim-0423d652
#   bash scripts/pause-aim-inference.sh demo   # pauses all AIM predictors in namespace
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${1:-demo}"
TARGET="${2:-}"

echo "=== pause-aim-inference (namespace=${NS}) ==="

pause_isvc() {
  local isvc="$1"
  echo "  Scaling InferenceService/${isvc} to 0 replicas..."
  kubectl patch inferenceservice "$isvc" -n "$NS" --type=json \
    -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0},{"op":"replace","path":"/spec/predictor/maxReplicas","value":0}]' \
    2>/dev/null || true
}

if [[ -n "$TARGET" ]]; then
  ISVCS=$(kubectl get inferenceservice -n "$NS" -o name 2>/dev/null | grep "$TARGET" || true)
  if [[ -z "$ISVCS" ]]; then
    echo "ERROR: No InferenceService matching ${TARGET} in ${NS}"
    exit 1
  fi
  for isvc in $ISVCS; do
    pause_isvc "${isvc#*/}"
  done
else
  for isvc in $(kubectl get inferenceservice -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    pause_isvc "$isvc"
  done
fi

echo ""
echo "Paused. AIMService and PVCs unchanged."
echo "Resume: patch minReplicas/maxReplicas back to 1, or re-Deploy from Workbench."
