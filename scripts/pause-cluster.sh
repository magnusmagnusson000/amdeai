#!/usr/bin/env bash
# Emergency quiesce: stop heavy cluster workloads without deleting data.
#
# Usage:
#   bash scripts/pause-cluster.sh          # scale down workloads, keep RKE2 running
#   bash scripts/pause-cluster.sh --stop   # also stop rke2-server
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/staged-startup.sh
source "$SCRIPT_DIR/lib/staged-startup.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "=== pause-cluster ==="

if kubectl get nodes &>/dev/null; then
  staged_argocd_suspend_autosync
  staged_quiesce_workloads
  staged_pause_inference
  echo "Workloads scaled to 0. RKE2 still running."
else
  echo "Kubernetes API not reachable — skipping workload scale."
fi

if [[ "${1:-}" == "--stop" ]]; then
  echo "Stopping rke2-server..."
  sudo systemctl stop rke2-server 2>/dev/null || sudo systemctl stop k3s 2>/dev/null || true
  echo "RKE2/k3s stopped."
fi

free -h | head -2
