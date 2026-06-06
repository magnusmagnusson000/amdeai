#!/usr/bin/env bash
# Pull latest commits for all study-tree repos under ~/eai-build/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TOP_LEVEL=(
  aim-engine cert-manager cluster-forge gateway-api k3s k8s-device-plugin
  kaiwo kserve kuberay kueue llama.cpp longhorn metallb
)
ROCM=(
  ROCm HIP clr rocm-systems ROCR-Runtime ROCm-Device-Libs llvm-project rocminfo rocm_smi_lib
)

pull_repo() {
  local dir="$1"
  if [[ ! -d "$dir/.git" ]]; then
    echo "SKIP (not a git repo): $dir"
    return 0
  fi
  echo "=== $dir ==="
  if git -C "$dir" pull --ff-only; then
    echo "OK: $(git -C "$dir" rev-parse --short HEAD) $(git -C "$dir" branch --show-current)"
  else
    echo "WARN: pull failed for $dir (detached HEAD or conflicts?)"
    git -C "$dir" status -sb || true
  fi
}

echo "Syncing ~/eai-build/ repositories..."
for name in "${TOP_LEVEL[@]}"; do
  pull_repo "$EAI_BUILD_DIR/$name"
done
for name in "${ROCM[@]}"; do
  pull_repo "$EAI_BUILD_DIR/rocm/$name"
done
echo "Done. See ~/eai-build/STACK_INDEX.md for inventory."
