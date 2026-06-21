#!/usr/bin/env bash
# Resume DiffusionGemma inference ONLY, with memory guards (gfx1151 freeze prevention).
#
# Prerequisites:
#   - Weights already downloaded (AIMArtifact Ready)
#   - bash scripts/pause-cluster.sh already run OR cluster otherwise quiesced
#   - No other AIM inference running
#
# Usage:
#   bash scripts/resume-diffusiongemma-inference.sh
#   KEEP_RUNNING=1 bash scripts/resume-diffusiongemma-inference.sh   # leave minReplicas=1 (unsafe on gfx1151)
#   MIN_MEM_AVAIL_GIB=80 bash scripts/resume-diffusiongemma-inference.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${AIM_NAMESPACE:-demo}"
MIN_MEM="${MIN_MEM_AVAIL_GIB:-80}"
ISVC="${DIFFUSIONGEMMA_ISVC:-diffusiongemma-26b-48844644}"
GPU_WARN_WINDOW_MIN="${GPU_WARN_WINDOW_MIN:-3}"
KEEP_RUNNING="${KEEP_RUNNING:-0}"

pause_inference() {
  bash "$SCRIPT_DIR/pause-aim-inference.sh" "${NS}" diffusiongemma || true
}

if [[ "${KEEP_RUNNING}" != "1" ]]; then
  trap pause_inference EXIT
fi

mem_avail_gib() {
  LANG=C free -g | awk '/^Mem:/{print $7}'
}

echo "=== resume-diffusiongemma-inference ==="
echo "Running hard preflight guard..."
bash "$SCRIPT_DIR/preflight-diffusiongemma-guard.sh"

AVAIL=$(mem_avail_gib)
echo "Memory available: ${AVAIL} GiB (minimum: ${MIN_MEM} GiB)"
if [[ "${AVAIL}" -lt "${MIN_MEM}" ]]; then
  echo "ERROR: Need >= ${MIN_MEM} GiB available memory before loading DiffusionGemma."
  echo "  Run: bash scripts/pause-cluster.sh"
  exit 2
fi

bash "$SCRIPT_DIR/pause-aim-inference.sh" "${NS}" || true

echo "Starting minimal operators (AIM engine, KServe, AIRM webhook)..."
kubectl scale deploy/aim-engine-controller-manager -n aim-system --replicas=1
kubectl scale deploy/kserve-controller-manager -n kserve-system --replicas=1
kubectl scale deploy/airm-agent-webhook -n airm --replicas=1
kubectl rollout status deploy/aim-engine-controller-manager -n aim-system --timeout=180s
kubectl rollout status deploy/kserve-controller-manager -n kserve-system --timeout=180s
kubectl rollout status deploy/airm-agent-webhook -n airm --timeout=180s

AVAIL=$(mem_avail_gib)
echo "Memory after operators: ${AVAIL} GiB available"
if [[ "${AVAIL}" -lt $((MIN_MEM - 10)) ]]; then
  echo "ERROR: Operators consumed too much memory (${AVAIL} GiB left)."
  exit 2
fi

bash "$SCRIPT_DIR/ensure-diffusiongemma-profile-mount.sh" "${NS}"
bash "$SCRIPT_DIR/fix-aim-httproute-gateway.sh" "${NS}" 2>/dev/null || true

echo "Scaling InferenceService/${ISVC} to 1 replica..."
kubectl patch inferenceservice "${ISVC}" -n "${NS}" --type=json \
  -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":1},{"op":"replace","path":"/spec/predictor/maxReplicas","value":1}]'

echo "Waiting for PredictorReady (max 30 min), monitoring memory..."
DEADLINE=$((SECONDS + 1800))
while (( SECONDS < DEADLINE )); do
  AVAIL=$(mem_avail_gib)
  GPU_WARNINGS=$( \
    (journalctl -k -b --since "${GPU_WARN_WINDOW_MIN} minutes ago" --no-pager \
      | rg -i 'amdgpu_amdkfd_restore_userptr_worker|svm_range_restore_work.*hogged CPU|Failed to resume KFD|queue evicted' \
      || true) \
    | awk 'NF{c++} END{print c+0}' \
  )
  READY=$(kubectl get inferenceservice "${ISVC}" -n "${NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="PredictorReady")].status}' 2>/dev/null || echo "")
  echo "  PredictorReady=${READY:-?} mem_avail=${AVAIL}GiB recent_gpu_warns=${GPU_WARNINGS}"
  if [[ "${AVAIL}" -lt 15 ]]; then
    echo "ERROR: Memory below 15 GiB — pausing inference to protect host."
    pause_inference
    exit 3
  fi
  if [[ "${GPU_WARNINGS}" -gt 0 ]]; then
    echo "ERROR: amdgpu/KFD stall warning detected while loading model; pausing inference."
    pause_inference
    exit 4
  fi
  POD_READY=$(kubectl get pods -n "${NS}" -l component=predictor \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)
  [[ "${POD_READY}" == "true" ]] && break
  sleep 30
done

POD_READY=$(kubectl get pods -n "${NS}" -l component=predictor \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)
if [[ "${POD_READY}" != "true" ]]; then
  echo "ERROR: Predictor pod not ready within timeout."
  kubectl get pods -n "${NS}" -l component=predictor
  exit 1
fi

READY=$(kubectl get inferenceservice "${ISVC}" -n "${NS}" \
  -o jsonpath='{.status.conditions[?(@.type=="PredictorReady")].status}' 2>/dev/null || echo "")
if [[ "${READY}" != "True" ]]; then
  echo "WARN: PredictorReady=${READY:-?} but pod container is ready."
fi

kubectl get aimservice diffusiongemma-26b -n "${NS}" -o wide 2>/dev/null || true
free -h | head -2
if [[ "${KEEP_RUNNING}" == "1" ]]; then
  echo "DiffusionGemma inference is up (KEEP_RUNNING=1). Run: bash scripts/run-diffusiongemma-perf.sh"
else
  trap - EXIT
  pause_inference
  echo "DiffusionGemma smoke resume complete; inference scaled back to 0 (set KEEP_RUNNING=1 to leave running)."
fi
