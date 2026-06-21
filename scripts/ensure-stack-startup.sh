#!/usr/bin/env bash
# Post-reboot startup hardening for the gfx1151 EAI stack.
#
# Run after RKE2/k3s comes up (or on login) to prevent Keycloak cgroup OOM thrash
# from freezing the host when amdgpu SVM restore work runs under memory pressure.
#
# Typical triggers:
#   - Reboot with large amdgpu GTT (GRUB gttsize/pages_limit for inference)
#   - Cold start of 30+ GitOps pods including Keycloak JVM JIT compile
#   - Before large Docker image builds (DiffusionGemma, Qwen AIM images)
#
# Usage:
#   bash scripts/ensure-stack-startup.sh
#   STACK_STARTUP_WAIT_KEYCLOAK=0 bash scripts/ensure-stack-startup.sh
#   bash scripts/install-stack-startup-service.sh   # auto-run after each boot
#
# See: docs/BLOOM_GFX1151_INSTALL.md (Troubleshooting — Keycloak OOM)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/stack-startup.sh
source "$SCRIPT_DIR/lib/stack-startup.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
KUBECTL_TIMEOUT="${STACK_STARTUP_KUBECTL_TIMEOUT:-300}"
WAIT_KEYCLOAK="${STACK_STARTUP_WAIT_KEYCLOAK:-1}"
KEYCLOAK_TIMEOUT="${STACK_STARTUP_KEYCLOAK_TIMEOUT:-600}"

echo "=== ensure-stack-startup ==="

stack_startup_wait_for_kubectl "$KUBECTL_TIMEOUT"
stack_startup_patch_keycloak_memory
stack_startup_cleanup_evicted_pods

if [[ "$WAIT_KEYCLOAK" == "1" ]]; then
  stack_startup_wait_for_keycloak "$KEYCLOAK_TIMEOUT" || {
    echo "WARN: Keycloak not Available yet — check: kubectl get pods -n keycloak"
    exit 1
  }
fi

echo ""
echo "Stack startup hardening complete."
disk_report "ensure-stack-startup-done"
