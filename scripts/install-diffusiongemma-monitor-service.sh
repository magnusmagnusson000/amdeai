#!/usr/bin/env bash
# Install systemd user service for continuous DiffusionGemma runtime monitoring.
#
# Usage:
#   bash scripts/install-diffusiongemma-monitor-service.sh
#   bash scripts/install-diffusiongemma-monitor-service.sh --uninstall
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EAI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~${USER_NAME}")"
KUBECONFIG_PATH="${KUBECONFIG:-${USER_HOME}/.kube/config}"
MONITOR_LOG_DIR="${MONITOR_LOG_DIR:-${USER_HOME}/amdeai-monitor/dg-telecom}"

UNIT="amdeai-dg-runtime-monitor.service"
UNIT_PATH="${USER_HOME}/.config/systemd/user/${UNIT}"

if [[ "${1:-}" == "--uninstall" ]]; then
  systemctl --user disable --now "${UNIT}" 2>/dev/null || true
  rm -f "${UNIT_PATH}"
  systemctl --user daemon-reload
  echo "Removed user systemd unit ${UNIT}"
  exit 0
fi

mkdir -p "${USER_HOME}/.config/systemd/user" "${MONITOR_LOG_DIR}"

cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=AMD EAI DiffusionGemma runtime watchdog (memory + hang detection)
Documentation=file://${EAI_ROOT}/docs/DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md
After=default.target

[Service]
Type=simple
Environment=HOME=${USER_HOME}
Environment=KUBECONFIG=${KUBECONFIG_PATH}
Environment=MONITOR_LOG_DIR=${MONITOR_LOG_DIR}
Environment=MONITOR_ABORT_ON_TRIP=1
ExecStart=/bin/bash ${EAI_ROOT}/scripts/monitor-diffusiongemma-runtime.sh
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now "${UNIT}"

echo "Installed and started: ${UNIT_PATH}"
echo "Logs: ${MONITOR_LOG_DIR}/alerts.log"
echo "Stop: systemctl --user stop ${UNIT}"
