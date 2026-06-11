#!/usr/bin/env bash
# Regenerate GRAPH_REPORT.md (cluster-only) and install Cursor rules for all graphified repos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=graphify-all.sh
source /dev/null 2>/dev/null || true

MODEL="${GRAPHIFY_MODEL:-qwen2.5-coder:7b}"
BACKEND="${GRAPHIFY_BACKEND:-ollama}"
LOG_DIR="${HOME}/.cache/amdeai/graphify-logs"
mkdir -p "$LOG_DIR"

export PYTHONUNBUFFERED=1
export OLLAMA_API_KEY="${OLLAMA_API_KEY:-local}"
export GRAPHIFY_OLLAMA_KEEP_ALIVE="${GRAPHIFY_OLLAMA_KEEP_ALIVE:-30m}"
export GRAPHIFY_OLLAMA_NUM_CTX="${GRAPHIFY_OLLAMA_NUM_CTX:-16384}"

ROCM="${HOME}/eai-build/rocm"
REPOS=(
  "/home/magnus/projects/amdeai"
  "${HOME}/eai-build/aim-engine"
  "${HOME}/eai-build/cert-manager"
  "${ROCM}/ROCm-Device-Libs"
  "${ROCM}/rocminfo"
  "${ROCM}/rocm_smi_lib"
  "${ROCM}/HIP"
  "${ROCM}/ROCm"
  "${HOME}/eai-build/k8s-device-plugin"
  "${HOME}/eai-build/longhorn"
  "${ROCM}/ROCR-Runtime"
  "${HOME}/eai-build/kaiwo"
  "${ROCM}/clr"
  "${HOME}/eai-build/k3s"
  "${HOME}/eai-build/metallb"
  "${HOME}/eai-build/kuberay"
  "${HOME}/eai-build/gateway-api"
  "${HOME}/eai-build/kueue"
  "${HOME}/eai-build/kserve"
  "${HOME}/eai-build/llama.cpp"
  "${ROCM}/rocm-systems"
  "${ROCM}/llvm-project"
  "${HOME}/eai-build/cluster-forge"
)

node_count() {
  python3 -c "import json; print(len(json.load(open('$1/graphify-out/graph.json')).get('nodes',[])))" 2>/dev/null || echo 0
}

for repo in "${REPOS[@]}"; do
  name="$(basename "$repo")"
  log="$LOG_DIR/${name}-postprocess.log"
  if [[ ! -f "$repo/graphify-out/graph.json" ]]; then
    echo "=== [$name] skip (no graph.json) ==="
    continue
  fi
  echo "=== [$name] postprocess ==="
  (
    cd "$repo"
    nodes="$(node_count "$repo")"
    extra=()
    if (( nodes > 5000 )); then
      extra+=(--no-viz)
      echo "[postprocess] $nodes nodes — skipping graph.html (--no-viz)"
    fi
    graphify cluster-only . --backend="$BACKEND" "${extra[@]}"
    graphify cursor install
    graphify hook install
  ) 2>&1 | tee "$log"
done

echo "All postprocess runs complete. Logs in $LOG_DIR"
