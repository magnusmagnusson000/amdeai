#!/usr/bin/env bash
# Continuous runtime watchdog for DiffusionGemma on gfx1151 (telecom + inference sessions).
#
# Monitors host memory PSI, KFD stall signatures, predictor health, and pod crash loops.
# On trip: logs alert, optionally pauses DiffusionGemma inference to protect the host.
#
# Usage:
#   bash scripts/monitor-diffusiongemma-runtime.sh
#   MONITOR_LOG_DIR=~/amdeai-monitor/dg-telecom bash scripts/monitor-diffusiongemma-runtime.sh &
#   GPU_OBSERVE_MODE=1 MONITOR_ABORT_ON_TRIP=0 bash scripts/monitor-diffusiongemma-runtime.sh
#
# Stop: kill $(cat "$MONITOR_LOG_DIR/monitor.pid") 2>/dev/null
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/diffusiongemma-guard.sh
source "$SCRIPT_DIR/lib/diffusiongemma-guard.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

MONITOR_LOG_DIR="${MONITOR_LOG_DIR:-${HOME}/amdeai-monitor/dg-telecom}"
MONITOR_ABORT_ON_TRIP="${MONITOR_ABORT_ON_TRIP:-1}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-60}"
HEALTH_FAIL_ABORT="${HEALTH_FAIL_ABORT:-3}"
POD_CHECK_INTERVAL="${POD_CHECK_INTERVAL:-60}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"
AIM_NAMESPACE="${AIM_NAMESPACE:-demo}"
DG_AIM_MODEL="${DG_AIM_MODEL:-google-diffusiongemma-26b}"
LLM_BRIDGE_URL="${LLM_BRIDGE_URL:-http://diffusiongemma-llm.default.svc.cluster.local}"
ALERT_LOG="${MONITOR_LOG_DIR}/alerts.log"
TIMELINE="${MONITOR_LOG_DIR}/memory-timeline.tsv"
PID_FILE="${MONITOR_LOG_DIR}/monitor.pid"

mkdir -p "${MONITOR_LOG_DIR}"
echo $$ > "${PID_FILE}"

trap 'rm -f "${PID_FILE}"; exit' INT TERM EXIT

export DG_BASELINE_GPU_CRITICAL="$(dg_recent_gpu_critical_count "${GPU_WARN_WINDOW_MIN}")"
export DG_BASELINE_GPU_BENIGN="$(dg_recent_gpu_benign_count "${GPU_WARN_WINDOW_MIN}")"
export DG_PSI_HIGH_SAMPLES=0

health_failures=0
last_watchdog=0
last_health=0
last_pod_check=0

log_alert() {
  local msg="$1"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ${msg}" | tee -a "${ALERT_LOG}"
}

abort_inference() {
  local reason="$1"
  log_alert "ABORT: ${reason}"
  if [[ "${MONITOR_ABORT_ON_TRIP}" == "1" ]]; then
    bash "${SCRIPT_DIR}/pause-aim-inference.sh" "${AIM_NAMESPACE}" diffusiongemma || true
  fi
}

mem_sample_loop() {
  while [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; do
    {
      date -u +"%Y-%m-%dT%H:%M:%SZ"
      LANG=C free -g | awk '/^Mem:/{printf "mem_avail_gib=%s total_gib=%s\n", $7, $2}'
      awk -F'[ =]' '/^some /{for(i=1;i<=NF;i++){if($i=="avg10"){print "psi_avg10=" $(i+1); exit}}}' /proc/pressure/memory || true
      echo "---"
    } >> "${TIMELINE}"
    sleep "${SAMPLE_INTERVAL}"
  done
}

check_predictor_pod() {
  local pod phase restarts ready
  pod="$(kubectl get pods -n "${AIM_NAMESPACE}" \
    -l "aim.eai.amd.com/model=${DG_AIM_MODEL},component=predictor" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod}" ]]; then
    return 0
  fi
  phase="$(kubectl get pod -n "${AIM_NAMESPACE}" "${pod}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  restarts="$(kubectl get pod -n "${AIM_NAMESPACE}" "${pod}" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
  ready="$(kubectl get pod -n "${AIM_NAMESPACE}" "${pod}" \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)"

  if [[ "${phase}" == "Failed" ]] || [[ "${restarts}" -ge 3 && "${ready}" != "true" ]]; then
    abort_inference "predictor pod ${pod} phase=${phase} restarts=${restarts}"
    return 1
  fi
  return 0
}

check_health() {
  local url="${LLM_BRIDGE_URL%/}/health"
  if curl -sf --max-time 15 "${url}" >/dev/null 2>&1; then
    health_failures=0
    return 0
  fi
  # Bridge may be unreachable from host; try predictor pod IP directly.
  local pod_ip
  pod_ip="$(kubectl get pods -A \
    -l "aim.eai.amd.com/model=${DG_AIM_MODEL},component=predictor" \
    -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].status.podIP}' 2>/dev/null \
    | awk '{print $1}')"
  if [[ -n "${pod_ip}" ]] && curl -sf --max-time 15 "http://${pod_ip}:8000/health" >/dev/null 2>&1; then
    health_failures=0
    return 0
  fi
  health_failures=$((health_failures + 1))
  log_alert "WARN: health check failed (${health_failures}/${HEALTH_FAIL_ABORT}) url=${url}"
  if [[ "${health_failures}" -ge "${HEALTH_FAIL_ABORT}" ]]; then
    log_alert "HANG: ${HEALTH_FAIL_ABORT} consecutive health failures"
    if [[ "${MONITOR_ABORT_ON_TRIP}" == "1" ]]; then
      local pod
      pod="$(kubectl get pods -n "${AIM_NAMESPACE}" \
        -l "aim.eai.amd.com/model=${DG_AIM_MODEL},component=predictor" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -n "${pod}" ]]; then
        log_alert "Deleting hung predictor pod ${pod} for KServe recreate"
        kubectl delete pod -n "${AIM_NAMESPACE}" "${pod}" --wait=false 2>/dev/null || true
      else
        abort_inference "health hang with no pod to restart"
      fi
    fi
    health_failures=0
    return 1
  fi
  return 0
}

echo "=== monitor-diffusiongemma-runtime ==="
echo "Log dir: ${MONITOR_LOG_DIR}"
echo "Baselines: gpu_critical=${DG_BASELINE_GPU_CRITICAL} gpu_benign=${DG_BASELINE_GPU_BENIGN}"
echo "PID: $$ (written to ${PID_FILE})"

mem_sample_loop &
SAMPLER_PID=$!

while [[ -f "${PID_FILE}" ]]; do
  now="${SECONDS}"

  if (( now - last_watchdog >= WATCHDOG_INTERVAL )); then
    last_watchdog=$now
    avail="$(dg_mem_avail_gib)"
    psi="$(dg_memory_psi_avg10)"
    if ! dg_watchdog_check_load; then
      abort_inference "${dg_abort_reason}"
    else
      echo "  OK mem_avail=${avail}GiB psi_avg10=${psi} psi_high_samples=${DG_PSI_HIGH_SAMPLES:-0}"
    fi
  fi

  if (( now - last_health >= HEALTH_INTERVAL )); then
    last_health=$now
    check_health || true
  fi

  if (( now - last_pod_check >= POD_CHECK_INTERVAL )); then
    last_pod_check=$now
    check_predictor_pod || true
  fi

  sleep 5
done

kill "${SAMPLER_PID}" 2>/dev/null || true
wait "${SAMPLER_PID}" 2>/dev/null || true
