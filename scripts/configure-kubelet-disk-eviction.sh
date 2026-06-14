#!/usr/bin/env bash
# Set kubelet eviction thresholds so disk-pressure taint fires only below 15 GiB free
# (instead of default ~10% / ~15% on root/imagefs — ~62–93 GiB on a 624 GiB disk).
#
# Usage:
#   bash scripts/configure-kubelet-disk-eviction.sh
#   DISK_EVICTION_HARD_GIB=15 SKIP_RESTART=1 bash scripts/configure-kubelet-disk-eviction.sh
#
# Requires: RKE2 (/etc/rancher/rke2/config.yaml), passwordless sudo for tee + systemctl.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

RKE2_CONFIG="${RKE2_CONFIG:-/etc/rancher/rke2/config.yaml}"
DISK_EVICTION_HARD_GIB="${DISK_EVICTION_HARD_GIB:-15}"
DISK_EVICTION_SOFT_GIB="${DISK_EVICTION_SOFT_GIB:-$((DISK_EVICTION_HARD_GIB + 5))}"
SKIP_RESTART="${SKIP_RESTART:-0}"
MARKER_BEGIN="# BEGIN AMDEAI MANAGED BLOCK - kubelet disk eviction"
MARKER_END="# END AMDEAI MANAGED BLOCK - kubelet disk eviction"

echo "=== configure-kubelet-disk-eviction (hard=${DISK_EVICTION_HARD_GIB}Gi soft=${DISK_EVICTION_SOFT_GIB}Gi) ==="

if [[ ! -f "$RKE2_CONFIG" ]]; then
  echo "ERROR: RKE2 config not found: $RKE2_CONFIG"
  exit 1
fi

eai_backup_file "$RKE2_CONFIG" "rke2-config.yaml.pre-disk-eviction"

tmp="$(mktemp)"
sudo cp "$RKE2_CONFIG" "$tmp"
sudo chown "$(id -u):$(id -g)" "$tmp"

python3 - "$tmp" "$MARKER_BEGIN" "$MARKER_END" "$DISK_EVICTION_HARD_GIB" "$DISK_EVICTION_SOFT_GIB" <<'PY'
import pathlib
import sys

path, begin, end, hard_gib, soft_gib = sys.argv[1:6]
text = pathlib.Path(path).read_text()
block = f"""{begin} ({hard_gib} GiB)
kubelet-arg:
  - "eviction-hard=memory.available<100Mi,nodefs.available<{hard_gib}Gi,imagefs.available<{hard_gib}Gi,nodefs.inodesFree<5%"
  - "eviction-soft=memory.available<500Mi,nodefs.available<{soft_gib}Gi,imagefs.available<{soft_gib}Gi"
  - "eviction-soft-grace-period=memory.available=1m30s,nodefs.available=1m30s,imagefs.available=1m30s"
  - "eviction-minimum-reclaim=nodefs.available=1Gi,imagefs.available=1Gi"
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

echo "Updated ${RKE2_CONFIG}:"
sudo grep -A6 'AMDEAI MANAGED BLOCK - kubelet disk eviction' "$RKE2_CONFIG" || true

if [[ "$SKIP_RESTART" == "1" ]]; then
  echo "SKIP_RESTART=1 — restart manually: sudo systemctl restart rke2-server"
  exit 0
fi

echo "Restarting rke2-server for kubelet eviction settings..."
sudo systemctl restart rke2-server
for _ in $(seq 1 60); do
  kubectl get nodes &>/dev/null && break
  sleep 5
done

kubectl wait --for=condition=Ready node/magnus-rog-flow-z13 --timeout=120s 2>/dev/null || true
sleep 10

if pgrep -af kubelet | grep -q "nodefs.available<${DISK_EVICTION_HARD_GIB}Gi"; then
  echo "Kubelet eviction-hard confirmed (nodefs.available<${DISK_EVICTION_HARD_GIB}Gi)."
else
  echo "WARN: could not verify eviction-hard in kubelet process args (check manually)."
fi

kubectl get node magnus-rog-flow-z13 -o jsonpath='DiskPressure={.status.conditions[?(@.type=="DiskPressure")].status} taints={.spec.taints}{"\n"}' 2>/dev/null || true
df -h / | tail -1
disk_report "configure-kubelet-disk-eviction-done"
