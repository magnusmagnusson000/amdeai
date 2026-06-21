#!/usr/bin/env bash
# Shared DiffusionGemma gfx1151 safety helpers (preflight + load watchdog).
# shellcheck shell=bash

# Observe mode: log KFD userptr warnings but do not abort on them alone.
# Still abort on critical stall signatures, memory pressure, and PSI spikes.
: "${GPU_OBSERVE_MODE:=0}"
: "${MIN_MEM_AVAIL_GIB:=80}"
: "${MIN_SWAP_GIB:=8}"
: "${GPU_WARN_WINDOW_MIN:=20}"
: "${MAX_MEM_PSI_AVG10:=0.50}"
: "${PSI_HIGH_SAMPLES_ABORT:=3}"
: "${MIN_MEM_ABORT_GIB:=15}"
: "${GPU_LOAD_MIN_MEM_ABORT_GIB:=8}"
: "${GPU_LOAD_MAX_MEM_PSI_AVG10:=2.50}"
: "${GPU_LOAD_PSI_HIGH_SAMPLES_ABORT:=6}"

dg_mem_avail_gib() {
  LANG=C free -g | awk '/^Mem:/{print $7}'
}

dg_swap_total_gib() {
  local total_bytes
  total_bytes="$(swapon --show --bytes --noheadings 2>/dev/null | awk '{s+=$3} END{print s+0}')"
  awk -v b="${total_bytes}" 'BEGIN {printf "%.0f", b/1024/1024/1024}'
}

dg_memory_psi_avg10() {
  awk -F'[ =]' '/^some /{for(i=1;i<=NF;i++){if($i=="avg10"){print $(i+1); exit}}}' /proc/pressure/memory
}

# Benign (observe-only) vs critical (abort even in observe mode).
dg_recent_gpu_benign_count() {
  local window_min="${1:-${GPU_WARN_WINDOW_MIN}}"
  local lines
  lines="$(
    journalctl -k -b --since "${window_min} minutes ago" --no-pager \
      | rg -i 'amdgpu_amdkfd_restore_userptr_worker|Failed to resume KFD' \
      || true
  )"
  printf "%s\n" "${lines}" | awk 'NF{c++} END{print c+0}'
}

dg_recent_gpu_critical_count() {
  local window_min="${1:-${GPU_WARN_WINDOW_MIN}}"
  local lines
  lines="$(
    journalctl -k -b --since "${window_min} minutes ago" --no-pager \
      | rg -i 'svm_range_restore_work.*hogged CPU|queue evicted|MES failed' \
      || true
  )"
  printf "%s\n" "${lines}" | awk 'NF{c++} END{print c+0}'
}

dg_recent_gpu_stall_count() {
  local benign critical
  benign="$(dg_recent_gpu_benign_count "$@")"
  critical="$(dg_recent_gpu_critical_count "$@")"
  echo $((benign + critical))
}

# Baselines captured at load start; watchdog compares deltas.
: "${DG_BASELINE_GPU_CRITICAL:=0}"
: "${DG_BASELINE_GPU_BENIGN:=0}"

# Returns 0 if load should continue, non-zero to abort.
# Sets dg_abort_reason on failure.
dg_watchdog_check_load() {
  local avail psi high_psi_samples="${DG_PSI_HIGH_SAMPLES:-0}"
  local critical benign critical_delta benign_delta
  dg_abort_reason=""

  local mem_abort_gib="${MIN_MEM_ABORT_GIB}"
  local psi_max="${MAX_MEM_PSI_AVG10}"
  local psi_samples_abort="${PSI_HIGH_SAMPLES_ABORT}"
  if [[ "${GPU_OBSERVE_MODE}" == "1" ]]; then
    mem_abort_gib="${GPU_LOAD_MIN_MEM_ABORT_GIB}"
    psi_max="${GPU_LOAD_MAX_MEM_PSI_AVG10}"
    psi_samples_abort="${GPU_LOAD_PSI_HIGH_SAMPLES_ABORT}"
  fi

  avail="$(dg_mem_avail_gib)"
  if [[ "${avail}" -lt "${mem_abort_gib}" ]]; then
    dg_abort_reason="memory below ${mem_abort_gib} GiB (${avail} GiB)"
    return 1
  fi

  psi="$(dg_memory_psi_avg10)"
  if awk -v psi="${psi}" -v max="${psi_max}" 'BEGIN {exit (psi>max)?0:1}'; then
    high_psi_samples=$((high_psi_samples + 1))
  else
    high_psi_samples=0
  fi
  DG_PSI_HIGH_SAMPLES="${high_psi_samples}"
  export DG_PSI_HIGH_SAMPLES

  if [[ "${high_psi_samples}" -ge "${psi_samples_abort}" ]]; then
    dg_abort_reason="memory PSI avg10=${psi} high for ${high_psi_samples} consecutive samples (max ${psi_max})"
    return 1
  fi

  critical="$(dg_recent_gpu_critical_count "${GPU_WARN_WINDOW_MIN}")"
  critical_delta=$((critical - DG_BASELINE_GPU_CRITICAL))
  if [[ "${critical_delta}" -gt 0 ]]; then
    dg_abort_reason="new critical amdgpu/KFD stall signature (+${critical_delta} since load start; ${critical} in last ${GPU_WARN_WINDOW_MIN} min)"
    return 1
  fi

  benign="$(dg_recent_gpu_benign_count "${GPU_WARN_WINDOW_MIN}")"
  benign_delta=$((benign - DG_BASELINE_GPU_BENIGN))
  if [[ "${GPU_OBSERVE_MODE}" != "1" ]] && [[ "${benign_delta}" -gt 0 ]]; then
    dg_abort_reason="new amdgpu/KFD userptr warning (+${benign_delta} since load start; set GPU_OBSERVE_MODE=1 to tolerate)"
    return 1
  fi

  return 0
}
