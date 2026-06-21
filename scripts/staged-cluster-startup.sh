#!/usr/bin/env bash
# Bring the EAI cluster up one ArgoCD Application at a time after reboot.
#
# Prevents the post-reboot memory storm (30+ pods + Keycloak JVM JIT + amdgpu SVM)
# that can freeze a gfx1151 host with 128 GiB unified memory and no swap.
#
# Install for automatic run after every boot:
#   bash scripts/install-staged-startup-service.sh
#
# Manual run (cluster already up):
#   bash scripts/staged-cluster-startup.sh
#
# Environment:
#   STAGED_STARTUP_PAUSE_SEC=20   pause between phases
#   STAGED_REENABLE_AUTOSYNC=1      restore ArgoCD auto-sync when done
#   STAGED_SKIP_QUIESCE=1           skip scaling workloads to 0 first
#   STAGED_START_PHASE=N            start at phase N (1-9) for resume
#
# See: docs/BLOOM_GFX1151_INSTALL.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/stack-startup.sh
source "$SCRIPT_DIR/lib/stack-startup.sh"
# shellcheck source=lib/staged-startup.sh
source "$SCRIPT_DIR/lib/staged-startup.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
LOCK_FILE="${HOME}/.cache/amdeai/staged-startup.lock"
START_PHASE="${STAGED_START_PHASE:-1}"

mkdir -p "$(dirname "$LOCK_FILE")"
if [[ -f "$LOCK_FILE" ]]; then
  echo "Staged startup already running (lock: $LOCK_FILE). Exit or rm lock if stale."
  exit 1
fi
echo $$ >"$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

echo "=== staged-cluster-startup (phase ${START_PHASE}+) ==="
staged_log "=== staged-cluster-startup begin ==="

stack_startup_wait_for_kubectl "${STACK_STARTUP_KUBECTL_TIMEOUT:-600}"
staged_ensure_argocd_controller
staged_argocd_suspend_autosync

if [[ "${STAGED_SKIP_QUIESCE:-0}" != "1" ]]; then
  staged_quiesce_workloads
fi
staged_pause_inference
stack_startup_cleanup_evicted_pods

# Patch Keycloak ArgoCD values before any sync wave reaches it
stack_startup_patch_keycloak_argocd 2>/dev/null || true

run_from_phase() {
  local n="$1"
  staged_load_phases
  if [[ $n -le 1 ]]; then staged_run_phase 1 "${STAGED_PHASE_1[@]}"; fi
  if [[ $n -le 2 ]]; then staged_run_phase 2 "${STAGED_PHASE_2[@]}"; fi
  if [[ $n -le 3 ]]; then staged_run_phase 3 "${STAGED_PHASE_3[@]}"; fi
  if [[ $n -le 4 ]]; then staged_run_phase 4 "${STAGED_PHASE_4[@]}"; fi
  if [[ $n -le 5 ]]; then staged_run_phase 5 "${STAGED_PHASE_5[@]}"; fi
  if [[ $n -le 6 ]]; then staged_run_phase 6 "${STAGED_PHASE_6[@]}"; fi
  if [[ $n -le 7 ]]; then staged_run_phase 7 "${STAGED_PHASE_7[@]}"; fi
  if [[ $n -le 8 ]]; then staged_run_phase 8 "${STAGED_PHASE_8[@]}"; fi
  if [[ $n -le 9 ]]; then staged_run_phase 9 "${STAGED_PHASE_9[@]}"; fi
}

run_from_phase "$START_PHASE"

staged_argocd_enable_autosync
staged_pause_inference

staged_log "=== staged-cluster-startup complete ==="
echo ""
echo "Cluster staged startup complete. Inference remains paused."
echo "  Resume a model: Deploy from AI Workbench, or patch InferenceService replicas."
echo "  Log: ${STAGED_STARTUP_LOG}"
disk_report "staged-cluster-startup-done"
