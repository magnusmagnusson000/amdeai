#!/usr/bin/env bash
# Hard safety gate before starting DiffusionGemma on gfx1151.
# Blocks startup when host or cluster signals elevated freeze risk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/diffusiongemma-guard.sh
source "$SCRIPT_DIR/lib/diffusiongemma-guard.sh"

MIN_MEM="${MIN_MEM_AVAIL_GIB:-80}"

echo "=== preflight-diffusiongemma-guard ==="
if [[ "${GPU_OBSERVE_MODE:-0}" == "1" ]]; then
  echo "GPU_OBSERVE_MODE=1: pre-existing benign KFD warnings allowed; critical stalls still block."
fi

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

SWAP_GIB="$(dg_swap_total_gib)"
if [[ "${SWAP_GIB}" -lt "${MIN_SWAP_GIB}" ]]; then
  echo "ERROR: swap too small (${SWAP_GIB} GiB < ${MIN_SWAP_GIB} GiB)."
  exit 2
fi

AVAIL="$(dg_mem_avail_gib)"
echo "Memory available: ${AVAIL} GiB (min: ${MIN_MEM} GiB)"
if [[ "${AVAIL}" -lt "${MIN_MEM}" ]]; then
  echo "ERROR: insufficient available memory."
  exit 2
fi

PSI="$(dg_memory_psi_avg10)"
awk -v psi="${PSI}" -v max="${MAX_MEM_PSI_AVG10}" 'BEGIN {exit (psi<=max)?0:1}' || {
  echo "ERROR: memory PSI avg10=${PSI} exceeds ${MAX_MEM_PSI_AVG10}."
  exit 2
}

GPU_CRITICAL="$(dg_recent_gpu_critical_count)"
GPU_BENIGN="$(dg_recent_gpu_benign_count)"
if [[ "${GPU_OBSERVE_MODE:-0}" == "1" ]]; then
  echo "Observe mode: skipping preflight stall history (load watchdog still active)."
elif [[ "${GPU_CRITICAL}" -gt 0 ]]; then
  echo "ERROR: detected ${GPU_CRITICAL} critical amdgpu/KFD stall signatures in last ${GPU_WARN_WINDOW_MIN} min."
  echo "  Keep inference paused and investigate kernel logs first."
  exit 2
elif [[ "${GPU_BENIGN}" -gt 0 ]]; then
  echo "ERROR: detected ${GPU_BENIGN} benign KFD userptr warnings in last ${GPU_WARN_WINDOW_MIN} min."
  echo "  Set GPU_OBSERVE_MODE=1 for supervised load, or investigate kernel logs first."
  exit 2
fi
if [[ "${GPU_BENIGN}" -gt 0 ]] && [[ "${GPU_OBSERVE_MODE:-0}" == "1" ]]; then
  echo "WARN: ${GPU_BENIGN} benign KFD userptr warnings present; proceeding under observe mode."
fi

echo "Preflight OK: swap active, memory healthy, no critical amdgpu stall signatures."
