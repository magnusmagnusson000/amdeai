#!/usr/bin/env bash
# Enable host swap for RKE2/k3s clusters that allow it (failSwapOn=false).
#
# RKE2 v1.32+ already sets failSwapOn: false in kubelet defaults; this script
# activates the host swap device and optionally enables LimitedSwap for Burstable pods.
#
# Usage:
#   bash scripts/enable-kubernetes-swap.sh
#   SWAP_FILE=/swap.img SWAP_SIZE_GIB=16 SKIP_RESTART=1 bash scripts/enable-kubernetes-swap.sh
#
# Requires: passwordless sudo.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

RKE2_CONFIG="${RKE2_CONFIG:-/etc/rancher/rke2/config.yaml}"
SWAP_FILE="${SWAP_FILE:-/swap.img}"
SWAP_SIZE_GIB="${SWAP_SIZE_GIB:-8}"
SWAP_BEHAVIOR="${SWAP_BEHAVIOR:-LimitedSwap}"
SKIP_RESTART="${SKIP_RESTART:-0}"
MARKER_BEGIN="# BEGIN AMDEAI MANAGED BLOCK - kubelet swap"
MARKER_END="# END AMDEAI MANAGED BLOCK - kubelet swap"
KUBELET_SWAP_CONF="/etc/rancher/rke2/amdeai-kubelet-swap.yaml"

echo "=== enable-kubernetes-swap (file=${SWAP_FILE} behavior=${SWAP_BEHAVIOR}) ==="

ensure_swap_file() {
  if [[ -f "$SWAP_FILE" ]]; then
    echo "Swap file exists: $SWAP_FILE ($(du -h "$SWAP_FILE" | awk '{print $1}'))"
    return 0
  fi
  echo "Creating ${SWAP_SIZE_GIB} GiB swap file at ${SWAP_FILE}..."
  sudo fallocate -l "${SWAP_SIZE_GIB}G" "$SWAP_FILE" 2>/dev/null \
    || sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_SIZE_GIB * 1024)) status=progress
  sudo chmod 600 "$SWAP_FILE"
  sudo mkswap "$SWAP_FILE"
}

enable_fstab_swap() {
  eai_backup_file /etc/fstab fstab.pre-swap
  if grep -E '^\s*[^#].*\sswap\s' /etc/fstab 2>/dev/null | grep -q .; then
    echo "Active swap entry already present in /etc/fstab."
    return 0
  fi
  if grep -q "^#.*${SWAP_FILE}" /etc/fstab 2>/dev/null; then
    sudo sed -i "s|^#\\(.*${SWAP_FILE}.*\\)|\\1|" /etc/fstab
    echo "Uncommented swap entry for ${SWAP_FILE} in /etc/fstab."
    return 0
  fi
  echo "${SWAP_FILE} none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
  echo "Added swap entry for ${SWAP_FILE} to /etc/fstab."
}

activate_swap() {
  if swapon --show 2>/dev/null | grep -q .; then
    echo "Swap already active:"
    swapon --show
    return 0
  fi
  sudo swapon "$SWAP_FILE"
  echo "Activated swap:"
  swapon --show
  free -h | grep -i swap || free -h | tail -1
}

configure_rke2_limited_swap() {
  [[ -f "$RKE2_CONFIG" ]] || return 0

  eai_backup_file "$RKE2_CONFIG" rke2-config.yaml.pre-swap
  eai_backup_file "$KUBELET_SWAP_CONF" amdeai-kubelet-swap.yaml 2>/dev/null || true

  sudo tee "$KUBELET_SWAP_CONF" >/dev/null <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
memorySwap:
  swapBehavior: ${SWAP_BEHAVIOR}
EOF

  tmp="$(mktemp)"
  sudo cp "$RKE2_CONFIG" "$tmp"
  sudo chown "$(id -u):$(id -g)" "$tmp"

  python3 - "$tmp" "$MARKER_BEGIN" "$MARKER_END" "$KUBELET_SWAP_CONF" <<'PY'
import pathlib
import sys

path, begin, end, swap_conf = sys.argv[1:5]
text = pathlib.Path(path).read_text()
config_arg = f'config={swap_conf}'
block = f"""{begin}
kubelet-arg:
  - "{config_arg}"
{end}
"""
if begin in text:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    text = pre.rstrip() + "\n\n" + block + post.lstrip("\n")
else:
    text = text.rstrip() + "\n\n" + block
pathlib.Path(path).write_text(text)
PY

  sudo cp "$tmp" "$RKE2_CONFIG"
  rm -f "$tmp"
  echo "Updated ${RKE2_CONFIG} with kubelet swap config (${SWAP_BEHAVIOR})."
}

ensure_swap_file
enable_fstab_swap
activate_swap
configure_rke2_limited_swap

if [[ -f "$RKE2_CONFIG" && "$SKIP_RESTART" != "1" ]]; then
  echo "Restarting rke2-server for kubelet swap settings..."
  sudo systemctl restart rke2-server
  for _ in $(seq 1 60); do
    kubectl get nodes &>/dev/null && break
    sleep 5
  done
  kubectl wait --for=condition=Ready node --all --timeout=180s 2>/dev/null || true
elif [[ -f "$RKE2_CONFIG" ]]; then
  echo "SKIP_RESTART=1 — restart manually: sudo systemctl restart rke2-server"
fi

echo "Swap status:"
swapon --show || true
free -h | grep -iE 'swap|Swap|Växl' || free -h | tail -1
disk_report "enable-kubernetes-swap-done"
