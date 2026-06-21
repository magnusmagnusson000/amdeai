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
#   GPU_OBSERVE_MODE=1 bash scripts/resume-diffusiongemma-inference.sh  # tolerate benign KFD warnings
#   MIN_MEM_AVAIL_GIB=80 bash scripts/resume-diffusiongemma-inference.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/diffusiongemma-guard.sh
source "$SCRIPT_DIR/lib/diffusiongemma-guard.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${AIM_NAMESPACE:-demo}"
MIN_MEM="${MIN_MEM_AVAIL_GIB:-80}"
ISVC="${DIFFUSIONGEMMA_ISVC:-diffusiongemma-26b-48844644}"
GPU_WARN_WINDOW_MIN="${GPU_WARN_WINDOW_MIN:-3}"
KEEP_RUNNING="${KEEP_RUNNING:-0}"
GPU_OBSERVE_MODE="${GPU_OBSERVE_MODE:-0}"
export GPU_OBSERVE_MODE GPU_WARN_WINDOW_MIN
DG_PSI_HIGH_SAMPLES=0

pause_inference() {
  bash "$SCRIPT_DIR/pause-aim-inference.sh" "${NS}" diffusiongemma || true
}

if [[ "${KEEP_RUNNING}" != "1" ]]; then
  trap pause_inference EXIT
fi

echo "=== resume-diffusiongemma-inference ==="
if [[ "${GPU_OBSERVE_MODE}" == "1" ]]; then
  echo "GPU_OBSERVE_MODE=1: benign KFD userptr warnings logged; critical stalls + PSI/memory still abort."
fi
echo "Running hard preflight guard..."
bash "$SCRIPT_DIR/preflight-diffusiongemma-guard.sh"

AVAIL=$(dg_mem_avail_gib)
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

AVAIL=$(dg_mem_avail_gib)
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
export DG_BASELINE_GPU_CRITICAL="$(dg_recent_gpu_critical_count "${GPU_WARN_WINDOW_MIN}")"
export DG_BASELINE_GPU_BENIGN="$(dg_recent_gpu_benign_count "${GPU_WARN_WINDOW_MIN}")"
echo "  Stall baselines: gpu_critical=${DG_BASELINE_GPU_CRITICAL} gpu_benign=${DG_BASELINE_GPU_BENIGN} (window=${GPU_WARN_WINDOW_MIN}min)"
while (( SECONDS < DEADLINE )); do
  AVAIL=$(dg_mem_avail_gib)
  GPU_BENIGN=$(dg_recent_gpu_benign_count "${GPU_WARN_WINDOW_MIN}")
  GPU_CRITICAL=$(dg_recent_gpu_critical_count "${GPU_WARN_WINDOW_MIN}")
  PSI=$(dg_memory_psi_avg10)
  READY=$(kubectl get inferenceservice "${ISVC}" -n "${NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="PredictorReady")].status}' 2>/dev/null || echo "")
  echo "  PredictorReady=${READY:-?} mem_avail=${AVAIL}GiB psi_avg10=${PSI} gpu_benign=${GPU_BENIGN} gpu_critical=${GPU_CRITICAL} psi_high_samples=${DG_PSI_HIGH_SAMPLES:-0}"
  if ! dg_watchdog_check_load; then
    echo "ERROR: Watchdog abort — ${dg_abort_reason}"
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
