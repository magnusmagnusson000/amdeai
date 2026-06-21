#!/usr/bin/env bash
# Hard safety gate before starting DiffusionGemma on gfx1151.
# Blocks startup when host or cluster signals elevated freeze risk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MIN_MEM="${MIN_MEM_AVAIL_GIB:-80}"
MIN_SWAP_GIB="${MIN_SWAP_GIB:-8}"
GPU_WARN_WINDOW_MIN="${GPU_WARN_WINDOW_MIN:-20}"
MAX_MEM_PSI_AVG10="${MAX_MEM_PSI_AVG10:-0.50}"

mem_avail_gib() {
  LANG=C free -g | awk '/^Mem:/{print $7}'
}

swap_total_gib() {
  local total_bytes
  total_bytes="$(swapon --show --bytes --noheadings 2>/dev/null | awk '{s+=$3} END{print s+0}')"
  awk -v b="${total_bytes}" 'BEGIN {printf "%.0f", b/1024/1024/1024}'
}

memory_psi_avg10() {
  awk -F'[ =]' '/^some /{for(i=1;i<=NF;i++){if($i=="avg10"){print $(i+1); exit}}}' /proc/pressure/memory
}

recent_gpu_stall_count() {
  local lines
  lines="$(
    journalctl -k -b --since "${GPU_WARN_WINDOW_MIN} minutes ago" --no-pager \
      | rg -i 'amdgpu_amdkfd_restore_userptr_worker|svm_range_restore_work.*hogged CPU|Failed to resume KFD|queue evicted' \
      || true
  )"
  printf "%s\n" "${lines}" | awk 'NF{c++} END{print c+0}'
}

echo "=== preflight-diffusiongemma-guard ==="

if [[ "$(systemctl is-active rke2-server 2>/dev/null || true)" != "active" ]]; then
  echo "ERROR: rke2-server is not active."
  exit 2
fi

if systemctl is-active --quiet rke2-server && systemctl show -p ActiveState --value rke2-server | rg -q '^activating$'; then
  echo "ERROR: rke2-server is still activating; wait before loading model."
  exit 2
fi

if ! swapon --show --noheadings | rg -q '.'; then
  echo "ERROR: no active swap detected."
  echo "  Run: bash scripts/enable-kubernetes-swap.sh"
  exit 2
fi

SWAP_GIB="$(swap_total_gib)"
if [[ "${SWAP_GIB}" -lt "${MIN_SWAP_GIB}" ]]; then
  echo "ERROR: swap too small (${SWAP_GIB} GiB < ${MIN_SWAP_GIB} GiB)."
  exit 2
fi

AVAIL="$(mem_avail_gib)"
echo "Memory available: ${AVAIL} GiB (min: ${MIN_MEM} GiB)"
if [[ "${AVAIL}" -lt "${MIN_MEM}" ]]; then
  echo "ERROR: insufficient available memory."
  exit 2
fi

PSI="$(memory_psi_avg10)"
awk -v psi="${PSI}" -v max="${MAX_MEM_PSI_AVG10}" 'BEGIN {exit (psi<=max)?0:1}' || {
  echo "ERROR: memory PSI avg10=${PSI} exceeds ${MAX_MEM_PSI_AVG10}."
  exit 2
}

GPU_WARNS="$(recent_gpu_stall_count)"
if [[ "${GPU_WARNS}" -gt 0 ]]; then
  echo "ERROR: detected ${GPU_WARNS} recent amdgpu/KFD stall warnings in last ${GPU_WARN_WINDOW_MIN} min."
  echo "  Keep inference paused and investigate kernel logs first."
  exit 2
fi

echo "Preflight OK: swap active, memory healthy, no recent amdgpu stall signatures."
