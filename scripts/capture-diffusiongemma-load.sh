#!/usr/bin/env bash
# Capture DiffusionGemma predictor load diagnostics (logs + kernel + memory timeline).
#
# Usage:
#   bash scripts/capture-diffusiongemma-load.sh start [label]
#   bash scripts/capture-diffusiongemma-load.sh stop
#   bash scripts/capture-diffusiongemma-load.sh run [label]   # start, resume load, stop
#
# Output: tests/perf/diag/<timestamp>_<label>/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${AIM_NAMESPACE:-demo}"
ISVC="${DIFFUSIONGEMMA_ISVC:-diffusiongemma-26b-48844644}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"
DIAG_ROOT="${DIAG_ROOT:-$EAI_ROOT/tests/perf/diag}"
STATE_FILE="${DIAG_ROOT}/.capture-active"

predictor_pod() {
  kubectl get pods -n "${NS}" -l component=predictor \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

start_capture() {
  local label="${1:-load}"
  local ts dir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="${DIAG_ROOT}/${ts}_${label}"
  mkdir -p "${dir}"

  cat > "${STATE_FILE}" <<EOF
DIR=${dir}
NS=${NS}
ISVC=${ISVC}
STARTED=${ts}
LABEL=${label}
EOF

  echo "=== capture-diffusiongemma-load start ==="
  echo "Output: ${dir}"

  {
    echo "# capture started ${ts} label=${label}"
    echo "namespace=${NS} isvc=${ISVC}"
    free -h
    swapon --show || true
    cat /proc/pressure/memory || true
  } > "${dir}/host-start.txt"

  journalctl -k -b --no-pager > "${dir}/kernel-boot.log" 2>/dev/null || true

  (
    while [[ -f "${STATE_FILE}" ]]; do
      date -u +"%Y-%m-%dT%H:%M:%SZ" >> "${dir}/memory-timeline.tsv"
      LANG=C free -g | awk '/^Mem:/{printf "mem_avail_gib=%s total_gib=%s\n", $7, $2}' >> "${dir}/memory-timeline.tsv"
      awk -F'[ =]' '/^some /{for(i=1;i<=NF;i++){if($i=="avg10"){print "psi_avg10=" $(i+1); exit}}}' /proc/pressure/memory >> "${dir}/memory-timeline.tsv" || true
      echo "---" >> "${dir}/memory-timeline.tsv"
      sleep "${SAMPLE_INTERVAL}"
    done
  ) &
  echo $! > "${dir}/mem-sampler.pid"

  (
    journalctl -k -f --no-pager >> "${dir}/kernel-follow.log" 2>&1
  ) &
  echo $! > "${dir}/kernel-follow.pid"

  local pod
  pod="$(predictor_pod)"
  if [[ -n "${pod}" ]]; then
    kubectl logs -n "${NS}" "${pod}" --all-containers=true > "${dir}/predictor-initial.log" 2>&1 || true
    (
      kubectl logs -n "${NS}" "${pod}" --all-containers=true -f >> "${dir}/predictor-follow.log" 2>&1
    ) &
    echo $! > "${dir}/predictor-follow.pid"
    echo "${pod}" > "${dir}/predictor-pod.txt"
  else
    echo "(no predictor pod yet)" > "${dir}/predictor-pod.txt"
    (
      while [[ -f "${STATE_FILE}" ]]; do
        pod="$(predictor_pod)"
        if [[ -n "${pod}" ]] && [[ ! -f "${dir}/predictor-follow.pid" ]]; then
          echo "${pod}" > "${dir}/predictor-pod.txt"
          kubectl logs -n "${NS}" "${pod}" --all-containers=true > "${dir}/predictor-initial.log" 2>&1 || true
          (
            kubectl logs -n "${NS}" "${pod}" --all-containers=true -f >> "${dir}/predictor-follow.log" 2>&1
          ) &
          echo $! > "${dir}/predictor-follow.pid"
          break
        fi
        sleep 5
      done
    ) &
    echo $! > "${dir}/predictor-wait.pid"
  fi

  echo "Capture running. Stop with: bash scripts/capture-diffusiongemma-load.sh stop"
}

stop_capture() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    echo "No active capture (missing ${STATE_FILE})."
    return 0
  fi

  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  local dir="${DIR}"

  echo "=== capture-diffusiongemma-load stop ==="
  echo "Finalizing: ${dir}"

  rm -f "${STATE_FILE}"

  for pidfile in mem-sampler kernel-follow predictor-follow predictor-wait; do
    if [[ -f "${dir}/${pidfile}.pid" ]]; then
      kill "$(cat "${dir}/${pidfile}.pid")" 2>/dev/null || true
      rm -f "${dir}/${pidfile}.pid"
    fi
  done

  {
    echo "# capture stopped $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    free -h
    swapon --show || true
    cat /proc/pressure/memory || true
    kubectl get inferenceservice "${ISVC}" -n "${NS}" -o wide 2>/dev/null || true
    kubectl get pods -n "${NS}" -l component=predictor -o wide 2>/dev/null || true
  } > "${dir}/host-end.txt"

  journalctl -k -b --since "@${STARTED}" --no-pager > "${dir}/kernel-since-start.log" 2>/dev/null || true

  local pod
  pod="$(predictor_pod)"
  if [[ -n "${pod}" ]]; then
    kubectl logs -n "${NS}" "${pod}" --all-containers=true --tail=-1 > "${dir}/predictor-final.log" 2>&1 || true
    kubectl describe pod -n "${NS}" "${pod}" > "${dir}/predictor-describe.txt" 2>&1 || true
  fi

  rg -i 'Failed to resume KFD|hogged CPU|queue evicted|MES failed|OOM|CUDA out of memory|HIP out of memory|graph capture|enforce-eager' \
    "${dir}" > "${dir}/highlights.txt" 2>/dev/null || true

  echo "Diagnostics saved to ${dir}"
  echo "Highlights:"
  head -30 "${dir}/highlights.txt" 2>/dev/null || echo "(none)"
}

run_capture() {
  local label="${1:-phase0}"
  start_capture "${label}"
  trap stop_capture EXIT
  GPU_OBSERVE_MODE=1 KEEP_RUNNING=1 bash "$SCRIPT_DIR/resume-diffusiongemma-inference.sh"
  local rc=$?
  stop_capture
  trap - EXIT
  return "${rc}"
}

cmd="${1:-run}"
case "${cmd}" in
  start) start_capture "${2:-load}" ;;
  stop) stop_capture ;;
  run) run_capture "${2:-phase0}" ;;
  *)
    echo "Usage: $0 {start|stop|run} [label]"
    exit 1
    ;;
esac
