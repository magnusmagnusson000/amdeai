#!/usr/bin/env bash
# Memory-safe DiffusionGemma perf benchmark + comparison vs Qwen baselines.
#
# Usage:
#   bash scripts/run-diffusiongemma-perf.sh
#   SKIP_RESUME=1 bash scripts/run-diffusiongemma-perf.sh   # predictor already Running
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${AIM_NAMESPACE:-demo}"
VENV="${EAI_VENV:-/home/magnus/projects/venvs/amd}"
OUT="${PERF_JSON_OUT:-/tmp/diffusiongemma-perf.json}"
MODEL="${PERF_MODEL:-google/diffusiongemma-26B-A4B-it}"

if [[ "${SKIP_RESUME:-0}" != "1" ]]; then
  bash "$SCRIPT_DIR/preflight-diffusiongemma-guard.sh"
  KEEP_RUNNING=1 bash "$SCRIPT_DIR/resume-diffusiongemma-inference.sh"
fi

NODE_IP="$(my_ip)"
ROUTE=$(kubectl get httproute -n "${NS}" -o name 2>/dev/null | grep -i diffusion | head -1 || true)
if [[ -n "${ROUTE}" ]]; then
  NAME="${ROUTE#*/}"
  AIM_PATH=$(kubectl get httproute "${NAME}" -n "${NS}" -o jsonpath='{.spec.rules[0].matches[0].path.value}' 2>/dev/null || echo "")
  ENDPOINT="https://${NODE_IP}${AIM_PATH}"
else
  IS_URL=$(kubectl get inferenceservice diffusiongemma-26b-48844644 -n "${NS}" \
    -o jsonpath='{.status.url}' 2>/dev/null || echo "")
  ENDPOINT="${IS_URL:-https://${NODE_IP}/demo/models/diffusiongemma-26b}"
fi

# Fall back to port-forward if gateway returns connection errors
if ! curl -sk --max-time 5 "${ENDPOINT%/}/health" -o /dev/null 2>/dev/null; then
  POD=$(kubectl get pods -n "${NS}" -l component=predictor --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${POD}" ]]; then
    PF_PORT="${PERF_PF_PORT:-18080}"
    kubectl port-forward -n "${NS}" "${POD}" "${PF_PORT}:8000" >/tmp/dg-pf.log 2>&1 &
    PF_PID=$!
    sleep 2
    ENDPOINT="http://127.0.0.1:${PF_PORT}"
    trap "kill ${PF_PID} 2>/dev/null || true" EXIT
    echo "Gateway unreachable; using port-forward ${ENDPOINT}"
  fi
fi

echo "Benchmark endpoint: ${ENDPOINT}"
echo "Model: ${MODEL}"

# shellcheck source=/dev/null
source "${VENV}/bin/activate"
pip install -q httpx pytest 2>/dev/null || true

python3 "$SCRIPT_DIR/bench-vllm-endpoint.py" "${ENDPOINT}" "${MODEL}" --json-out "${OUT}"
python3 "$SCRIPT_DIR/compare-model-perf.py" "${OUT}" --label "DiffusionGemma 26B"

echo ""
echo "Pytest suite (same metrics as Qwen MoE):"
PERF_ENDPOINT="${ENDPOINT}" PERF_MODEL="${MODEL}" \
  pytest "$EAI_ROOT/tests/perf/test_diffusiongemma_perf.py" -v -s
