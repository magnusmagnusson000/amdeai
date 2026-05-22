#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "00-prerequisites"

echo "=== 00-prerequisites (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
disk_report "00-prerequisites-start" --baseline

# Always refresh apt metadata when sudo available
if sudo -n true 2>/dev/null; then
  sudo apt update
  sudo apt install -y \
    git curl wget build-essential cmake ninja-build \
    python3-pip python3-venv python3-dev \
    pkg-config libssl-dev zlib1g-dev \
    glslang-tools libvulkan-dev vulkan-tools
else
  echo "WARN: sudo not available — ensure build deps installed manually."
fi

# Go 1.23 — always re-extract when forcing
GO_ROOT="${GO_ROOT:-$HOME/.local/go}"
GO_TAR=go1.23.8.linux-amd64.tar.gz
if eai_force_enabled; then
  rm -rf "$GO_ROOT"
fi
if [[ ! -x "$GO_ROOT/bin/go" ]]; then
  wget -q "https://go.dev/dl/${GO_TAR}" -O "/tmp/${GO_TAR}"
  mkdir -p "$(dirname "$GO_ROOT")"
  tar -C "$(dirname "$GO_ROOT")" -xzf "/tmp/${GO_TAR}"
fi
export PATH="$GO_ROOT/bin:$HOME/go/bin:$PATH"

# Helm — reinstall when forcing and sudo available; else keep existing binary
if ! command -v helm &>/dev/null; then
  if sudo -n true 2>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    mkdir -p "$HOME/.local/bin"
    HELM_VER=v3.21.0
    curl -fsSL "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz" | tar -xz -C /tmp
    cp "/tmp/linux-amd64/helm" "$HOME/.local/bin/helm"
    chmod +x "$HOME/.local/bin/helm"
  fi
elif eai_force_enabled && sudo -n true 2>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "Keeping existing helm: $(helm version --short 2>/dev/null)"
fi

# kubectl — always re-download when forcing
mkdir -p "$HOME/.local/bin"
if eai_force_enabled || ! command -v kubectl &>/dev/null; then
  KVER=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl" -o "$HOME/.local/bin/kubectl"
  chmod +x "$HOME/.local/bin/kubectl"
fi
export PATH="$HOME/.local/bin:$PATH"

if ! groups | grep -q docker; then
  sudo -n usermod -aG docker "$USER" 2>/dev/null || echo "WARN: add user to docker group manually"
fi

if eai_force_enabled && command -v devbox &>/dev/null; then
  echo "[force] devbox already present; skip reinstall (use EAI_INSTALL_DEVBOX=1 to reinstall)"
elif [[ "${EAI_INSTALL_DEVBOX:-0}" == "1" ]]; then
  curl -fsSL https://get.jetpack.io/devbox | bash -s -- -f
fi

bash "$EAI_ROOT/scripts/lib/install-build-tools.sh"
if ! command -v yq &>/dev/null; then
  curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
    -o "$HOME/.local/bin/yq" && chmod +x "$HOME/.local/bin/yq"
fi
export PATH="${HOME}/.local/bin:${PATH}"

activate_venv
pip install -q -U pip
pip install -q --force-reinstall -r "$EAI_ROOT/tests/requirements.txt"
playwright install chromium

mkdir -p "$EAI_BUILD_DIR"
disk_report "00-prerequisites-done"
echo "Prerequisites complete. Go: $(go version)"
