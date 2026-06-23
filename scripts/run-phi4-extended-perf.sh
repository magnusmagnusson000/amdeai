#!/usr/bin/env bash
# Extended Phi-4 14B perf run: same metrics as run-diffusiongemma-extended-perf.sh.
#
# Usage:
#   bash scripts/run-phi4-extended-perf.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${AIM_NAMESPACE:-demo}"
VENV="${EAI_VENV:-/home/magnus/projects/venvs/amd}"
MODEL="${PERF_MODEL:-microsoft/phi-4}"
PHI_AIM_MODEL="${PHI_AIM_MODEL:-microsoft-phi-4-14b}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${PERF_OUT_DIR:-$EAI_ROOT/tests/perf/runs/${TS}_phi4-14b-extended}"
OUT_JSON="${OUT_DIR}/results.json"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"

mkdir -p "${OUT_DIR}"

mem_avail_gib() {
  LANG=C free -g | awk '/^Mem:/{print $7}'
}

mem_sample_loop() {
  while [[ -f "${OUT_DIR}/.sampling" ]]; do
    {
      date -u +"%Y-%m-%dT%H:%M:%SZ"
      LANG=C free -g | awk '/^Mem:/{printf "mem_avail_gib=%s used_gib=%s\n", $7, $3}'
      awk -F'[ =]' '/^some /{for(i=1;i<=NF;i++){if($i=="avg10"){print "psi_avg10=" $(i+1); exit}}}' /proc/pressure/memory || true
      echo "---"
    } >> "${OUT_DIR}/memory-timeline.tsv"
    sleep "${SAMPLE_INTERVAL}"
  done
}

check_logs_after_run() {
  local pod="$1"
  echo ""
  echo "=== Post-run log check ==="
  {
    echo "# post-run $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    LANG=C free -h
    cat /proc/pressure/memory || true
  } > "${OUT_DIR}/host-end.txt"

  journalctl -k -b --since "@${TS}" --no-pager > "${OUT_DIR}/kernel-since-start.log" 2>/dev/null || true
  rg -i 'Failed to resume KFD|hogged CPU|queue evicted|MES failed|OOM|CUDA out of memory|HIP out of memory|ERROR|Traceback' \
    "${OUT_DIR}" > "${OUT_DIR}/highlights.txt" 2>/dev/null || true

  if [[ -n "${pod}" ]]; then
    kubectl logs -n "${NS}" "${pod}" --all-containers=true --tail=200 > "${OUT_DIR}/predictor-tail.log" 2>&1 || true
    rg -i 'ERROR |Traceback|OOM|CUDA out of memory|HIP out of memory|EngineCore failed|RuntimeError' \
      "${OUT_DIR}/predictor-tail.log" \
      > "${OUT_DIR}/predictor-errors.txt" 2>/dev/null || true
  fi
}

echo "=== run-phi4-extended-perf ==="
echo "Output: ${OUT_DIR}"

{
  echo "# start ${TS}"
  LANG=C free -h
  swapon --show || true
} > "${OUT_DIR}/host-start.txt"

bash "$SCRIPT_DIR/ensure-diffusiongemma-paused.sh" demo default || true

POD=$(kubectl get pods -A -l "aim.eai.amd.com/model=${PHI_AIM_MODEL},component=predictor" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
POD_NS=$(kubectl get pods -A -l "aim.eai.amd.com/model=${PHI_AIM_MODEL},component=predictor" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)

if [[ -z "${POD}" ]]; then
  POD=$(kubectl get pods -n "${NS}" -l component=predictor --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  POD_NS="${NS}"
fi

if [[ -z "${POD}" ]]; then
  echo "ERROR: no Running Phi-4 predictor pod (model=${PHI_AIM_MODEL})"
  exit 1
fi

PF_PORT="${PERF_PF_PORT:-18083}"
kubectl port-forward -n "${POD_NS}" "${POD}" "${PF_PORT}:8000" >"${OUT_DIR}/port-forward.log" 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true; rm -f "${OUT_DIR}/.sampling"; check_logs_after_run "${POD:-}"' EXIT
sleep 2

if ! curl -sf --max-time 10 "http://127.0.0.1:${PF_PORT}/health" >/dev/null; then
  echo "ERROR: predictor health check failed on port ${PF_PORT}"
  exit 1
fi

ENDPOINT="http://127.0.0.1:${PF_PORT}"
echo "Benchmark endpoint: ${ENDPOINT} (pod ${POD_NS}/${POD})"
echo "Mem before benchmark: $(mem_avail_gib) GiB available"

touch "${OUT_DIR}/.sampling"
mem_sample_loop &
SAMPLER_PID=$!

# shellcheck source=/dev/null
source "${VENV}/bin/activate"
pip install -q httpx 2>/dev/null || true

set +e
python3 "$SCRIPT_DIR/bench-vllm-extended.py" "${ENDPOINT}" "${MODEL}" \
  --ttft-runs 3 \
  --json-out "${OUT_JSON}" \
  2>&1 | tee "${OUT_DIR}/bench.log"
BENCH_RC=$?
set -e

rm -f "${OUT_DIR}/.sampling"
wait "${SAMPLER_PID}" 2>/dev/null || true

echo ""
echo "Mem after benchmark: $(mem_avail_gib) GiB available"
python3 "$SCRIPT_DIR/compare-model-perf.py" "${OUT_JSON}" --label "Phi-4 14B (extended)" || true

exit "${BENCH_RC}"
