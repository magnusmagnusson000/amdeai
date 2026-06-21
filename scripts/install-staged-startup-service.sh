#!/usr/bin/env bash
# Install systemd services for staged post-reboot cluster startup.
#
# - amdeai-staged-cluster-startup.service (system): runs after rke2-server
# - amdeai-cluster-quiesce.service (system): scales workloads down before shutdown
#
# Usage:
#   bash scripts/install-staged-startup-service.sh
#   bash scripts/install-staged-startup-service.sh --uninstall
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EAI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~${USER_NAME}")"
KUBECONFIG_PATH="${KUBECONFIG:-${USER_HOME}/.kube/config}"

STARTUP_UNIT="amdeai-staged-cluster-startup.service"
QUIESCE_UNIT="amdeai-cluster-quiesce.service"
STARTUP_PATH="/etc/systemd/system/${STARTUP_UNIT}"
QUIESCE_PATH="/etc/systemd/system/${QUIESCE_UNIT}"

if [[ "${1:-}" == "--uninstall" ]]; then
  sudo systemctl disable --now "$STARTUP_UNIT" 2>/dev/null || true
  sudo systemctl disable "$QUIESCE_UNIT" 2>/dev/null || true
  sudo rm -f "$STARTUP_PATH" "$QUIESCE_PATH"
  sudo systemctl daemon-reload
  echo "Removed staged startup systemd units."
  exit 0
fi

if ! sudo -n true 2>/dev/null; then
  echo "This installer requires sudo."
  exit 1
fi

sudo tee "$STARTUP_PATH" >/dev/null <<EOF
[Unit]
Description=AMD EAI staged cluster startup (one app at a time after reboot)
Documentation=file://${EAI_ROOT}/docs/BLOOM_GFX1151_INSTALL.md
After=rke2-server.service
Wants=rke2-server.service
ConditionPathExists=${KUBECONFIG_PATH}

[Service]
Type=oneshot
User=${USER_NAME}
Group=${USER_NAME}
Environment=HOME=${USER_HOME}
Environment=KUBECONFIG=${KUBECONFIG_PATH}
Environment=STAGED_STARTUP_PAUSE_SEC=20
Environment=STAGED_REENABLE_AUTOSYNC=1
Environment=KEYCLOAK_MEMORY_LIMIT=4Gi
Environment=KEYCLOAK_MEMORY_REQUEST=2Gi
ExecStartPre=/bin/sleep 30
ExecStart=/bin/bash ${EAI_ROOT}/scripts/staged-cluster-startup.sh
TimeoutStartSec=7200
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo tee "$QUIESCE_PATH" >/dev/null <<EOF
[Unit]
Description=AMD EAI quiesce cluster workloads before shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
After=network.target

[Service]
Type=oneshot
User=${USER_NAME}
Group=${USER_NAME}
Environment=HOME=${USER_HOME}
Environment=KUBECONFIG=${KUBECONFIG_PATH}
ExecStart=/bin/bash ${EAI_ROOT}/scripts/pause-cluster.sh
TimeoutStartSec=120
RemainAfterExit=yes

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$STARTUP_UNIT" "$QUIESCE_UNIT"

echo "Installed:"
echo "  ${STARTUP_PATH}"
echo "  ${QUIESCE_PATH}"
echo ""
echo "On reboot: rke2-server starts → wait 30s → staged-cluster-startup (phases 1-9)."
echo "On shutdown: pause-cluster scales heavy workloads to 0 first."
echo ""
echo "Suspend ArgoCD auto-sync now (persists until staged startup completes each boot):"
export KUBECONFIG="$KUBECONFIG_PATH"
if kubectl get nodes &>/dev/null 2>&1; then
  EAI_ROOT="$EAI_ROOT" \
  # shellcheck source=lib/common.sh
  source "$EAI_ROOT/scripts/lib/common.sh"
  # shellcheck source=lib/stack-startup.sh
  source "$EAI_ROOT/scripts/lib/stack-startup.sh"
  # shellcheck source=lib/staged-startup.sh
  source "$EAI_ROOT/scripts/lib/staged-startup.sh"
  staged_argocd_suspend_autosync
  stack_startup_patch_keycloak_argocd 2>/dev/null || true
  echo "ArgoCD auto-sync suspended; Keycloak memory patch applied."
else
  echo "Cluster not up — run staged startup manually after: sudo systemctl start rke2-server"
fi
echo ""
echo "Test staged startup now:"
echo "  sudo systemctl start ${STARTUP_UNIT}"
echo "Status / logs:"
echo "  sudo systemctl status ${STARTUP_UNIT}"
echo "  journalctl -u ${STARTUP_UNIT} -f"
echo "  tail -f ${USER_HOME}/.cache/amdeai/staged-startup.log"
