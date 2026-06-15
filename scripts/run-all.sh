#!/usr/bin/env bash
# Full forced build of all layers. Requires sudo for host/k3s steps.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export EAI_FORCE_REBUILD=1
export EAI_GRUB_APPLY_GUIDE_VALUES="${EAI_GRUB_APPLY_GUIDE_VALUES:-1}"

export EAI_MIN_FREE_GB="${EAI_MIN_FREE_GB:-15}"

run_step() {
  local script="$1"
  source "$SCRIPT_DIR/lib/common.sh"
  check_disk_before_step "$(basename "$script" .sh)"
  bash "$script" || { rc=$?; [[ $rc -eq 2 ]] && echo "PAUSED: disk space"; exit 2; return $rc; }
}

echo "Starting full EAI suite build (force=${EAI_FORCE_REBUILD}, min free ${EAI_MIN_FREE_GB} GiB)"
run_step "$SCRIPT_DIR/00-prerequisites.sh"
run_step "$SCRIPT_DIR/01-host-rocm.sh"
echo "If 01-host-rocm requested reboot, run: sudo reboot && re-run from 02-kubernetes.sh"
run_step "$SCRIPT_DIR/02-kubernetes.sh"
run_step "$SCRIPT_DIR/03-gpu-plugin.sh"
run_step "$SCRIPT_DIR/04-platform.sh"
run_step "$SCRIPT_DIR/05a-cluster-forge.sh"
run_step "$SCRIPT_DIR/05b-kaiwo.sh"
run_step "$SCRIPT_DIR/06a-aim-engine.sh"
run_step "$SCRIPT_DIR/06b-airm-workbench.sh"

source /home/magnus/projects/venvs/amd/bin/activate
cd "$(dirname "$SCRIPT_DIR")"
pytest tests/build tests/integration -v --tb=short
echo "E2E (optional): E2E_AIWB=1 E2E_AIRM=1 E2E_ARGOCD=1 pytest tests/e2e -v"
echo "Done. Disk log: ~/.cache/amdeai/disk-log.txt"
