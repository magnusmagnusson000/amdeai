#!/usr/bin/env bash
# Staged post-reboot cluster orchestration helpers.
# shellcheck source=stack-startup.sh
set -euo pipefail

STAGED_STARTUP_LOG="${STAGED_STARTUP_LOG:-${HOME}/.cache/amdeai/staged-startup.log}"
STAGED_STARTUP_PAUSE_SEC="${STAGED_STARTUP_PAUSE_SEC:-20}"
STAGED_APP_TIMEOUT="${STAGED_APP_TIMEOUT:-600}"

staged_log() {
  local msg="[$(date -Iseconds)] $*"
  echo "$msg"
  mkdir -p "$(dirname "$STAGED_STARTUP_LOG")"
  echo "$msg" >>"$STAGED_STARTUP_LOG"
}

staged_load_phases() {
  local conf="${EAI_ROOT}/scripts/config/staged-startup-phases.conf"
  # shellcheck source=/dev/null
  source "$conf"
  STAGED_ALL_PHASES=(
    "${STAGED_PHASE_1[@]}"
    "${STAGED_PHASE_2[@]}"
    "${STAGED_PHASE_3[@]}"
    "${STAGED_PHASE_4[@]}"
    "${STAGED_PHASE_5[@]}"
    "${STAGED_PHASE_6[@]}"
    "${STAGED_PHASE_7[@]}"
    "${STAGED_PHASE_8[@]}"
    "${STAGED_PHASE_9[@]}"
  )
}

staged_argocd_suspend_autosync() {
  staged_log "Suspending ArgoCD automated sync on all Applications..."
  local app
  for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch application "$app" -n argocd --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null || true
  done
}

staged_argocd_enable_autosync() {
  if [[ "${STAGED_REENABLE_AUTOSYNC:-1}" != "1" ]]; then
    staged_log "Skipping ArgoCD auto-sync re-enable (STAGED_REENABLE_AUTOSYNC=0)."
    return 0
  fi
  staged_log "Re-enabling ArgoCD automated sync..."
  local app
  for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    # aiwb was already manual in some installs — still enable for drift correction
    kubectl patch application "$app" -n argocd --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true
  done
}

staged_ensure_argocd_controller() {
  if kubectl get statefulset argocd-application-controller -n argocd &>/dev/null; then
    local replicas
    replicas=$(kubectl get statefulset argocd-application-controller -n argocd \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [[ "$replicas" == "0" ]]; then
      staged_log "Scaling ArgoCD application-controller back to 1..."
      kubectl scale statefulset argocd-application-controller -n argocd --replicas=1
      kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
    fi
  fi
}

staged_quiesce_workloads() {
  # shellcheck source=/dev/null
  source "${EAI_ROOT}/scripts/config/staged-startup-phases.conf"
  staged_log "Quiescing workloads (scale Deployments/StatefulSets to 0)..."
  local ns
  for ns in "${STAGED_QUIESCE_NAMESPACES[@]}"; do
    kubectl scale deployment --all -n "$ns" --replicas=0 2>/dev/null || true
    kubectl scale statefulset --all -n "$ns" --replicas=0 2>/dev/null || true
  done
  # InferenceServices keep respawning predictors — patch all to 0
  local isvc ns
  for ns in demo default; do
    for isvc in $(kubectl get inferenceservice -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      kubectl patch inferenceservice "$isvc" -n "$ns" --type=json \
        -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0},{"op":"replace","path":"/spec/predictor/maxReplicas","value":0}]' \
        2>/dev/null || true
    done
  done
  sleep 5
}

staged_pause_inference() {
  staged_log "Ensuring AIM inference stays paused (demo namespace)..."
  bash "${EAI_ROOT}/scripts/pause-aim-inference.sh" demo 2>/dev/null || true
}

staged_app_exists() {
  kubectl get application "$1" -n argocd &>/dev/null
}

staged_sync_application() {
  local app="$1"
  local timeout="${2:-$STAGED_APP_TIMEOUT}"
  if ! staged_app_exists "$app"; then
    staged_log "  skip ${app} (no ArgoCD Application)"
    return 0
  fi
  staged_log "  sync ${app} (timeout ${timeout}s)..."
  local rev
  rev=$(kubectl get application "$app" -n argocd -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || echo "HEAD")
  kubectl patch application "$app" -n argocd --type=merge \
    -p "{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"hard\"}},\"operation\":{\"initiatedBy\":{\"username\":\"staged-startup\"},\"sync\":{\"revision\":\"${rev}\"}}}" \
    2>/dev/null || true

  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local sync health op
    sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
    health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
    op=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "")
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      staged_log "  ${app}: Synced + Healthy (${elapsed}s)"
      return 0
    fi
    if [[ "$sync" == "Synced" && "$health" == "Degraded" ]]; then
      staged_log "  WARN: ${app} Synced but Degraded — continuing (${elapsed}s)"
      return 0
    fi
    if [[ "$op" == "Failed" ]]; then
      staged_log "  WARN: ${app} sync operation Failed — continuing"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  staged_log "  WARN: ${app} timed out (sync=${sync:-?} health=${health:-?}) — continuing"
  return 0
}

staged_run_phase() {
  local phase_num="$1"
  shift
  local apps=("$@")
  staged_log "=== Phase ${phase_num}: ${#apps[@]} application(s) ==="
  local app
  for app in "${apps[@]}"; do
    if [[ "$app" == "keycloak" ]]; then
      stack_startup_patch_keycloak_memory || true
    fi
    staged_sync_application "$app"
    if [[ "$app" == "keycloak" ]]; then
      stack_startup_wait_for_keycloak "${KEYCLOAK_TIMEOUT:-900}" || \
        staged_log "WARN: Keycloak deployment not Available yet"
    fi
  done
  staged_log "Phase ${phase_num} complete — pausing ${STAGED_STARTUP_PAUSE_SEC}s..."
  sleep "$STAGED_STARTUP_PAUSE_SEC"
}

staged_run_all_phases() {
  staged_load_phases
  staged_run_phase 1 "${STAGED_PHASE_1[@]}"
  staged_run_phase 2 "${STAGED_PHASE_2[@]}"
  staged_run_phase 3 "${STAGED_PHASE_3[@]}"
  staged_run_phase 4 "${STAGED_PHASE_4[@]}"
  staged_run_phase 5 "${STAGED_PHASE_5[@]}"
  staged_run_phase 6 "${STAGED_PHASE_6[@]}"
  staged_run_phase 7 "${STAGED_PHASE_7[@]}"
  staged_run_phase 8 "${STAGED_PHASE_8[@]}"
  staged_run_phase 9 "${STAGED_PHASE_9[@]}"
}
