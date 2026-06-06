#!/usr/bin/env bash
# Build graphify knowledge graphs for amdeai and all eai-build repos.
set -euo pipefail

# qwen3:8b thinking mode times out on Graphify JSON extraction; coder model is faster/reliable.
MODEL="${GRAPHIFY_MODEL:-qwen2.5-coder:7b}"
BACKEND="${GRAPHIFY_BACKEND:-ollama}"
LOG_DIR="${HOME}/.cache/amdeai/graphify-logs"
API_TIMEOUT="${GRAPHIFY_API_TIMEOUT:-1800}"
TOKEN_BUDGET="${GRAPHIFY_TOKEN_BUDGET:-8192}"
mkdir -p "$LOG_DIR"

export PYTHONUNBUFFERED=1
export OLLAMA_API_KEY="${OLLAMA_API_KEY:-local}"
export GRAPHIFY_OLLAMA_KEEP_ALIVE="${GRAPHIFY_OLLAMA_KEEP_ALIVE:-30m}"
# Avoid over-allocating KV cache (Ollama clamps qwen3 to 40960 anyway).
export GRAPHIFY_OLLAMA_NUM_CTX="${GRAPHIFY_OLLAMA_NUM_CTX:-16384}"

REPOS=(
  "/home/magnus/projects/amdeai"
  "${HOME}/eai-build/aim-engine"
  "${HOME}/eai-build/cert-manager"
  "${HOME}/eai-build/cluster-forge"
  "${HOME}/eai-build/gateway-api"
  "${HOME}/eai-build/k3s"
  "${HOME}/eai-build/k8s-device-plugin"
  "${HOME}/eai-build/kaiwo"
  "${HOME}/eai-build/kserve"
  "${HOME}/eai-build/kuberay"
  "${HOME}/eai-build/kueue"
  "${HOME}/eai-build/llama.cpp"
  "${HOME}/eai-build/longhorn"
  "${HOME}/eai-build/metallb"
)

if ! ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
  echo "error: ollama model '$MODEL' not found. Run: ollama pull $MODEL" >&2
  exit 1
fi

for repo in "${REPOS[@]}"; do
  name="$(basename "$repo")"
  log="$LOG_DIR/${name}.log"
  if [[ -f "$repo/graphify-out/graph.json" ]]; then
    echo "=== [$name] skip (graph.json exists) ==="
    continue
  fi
  echo "=== [$name] graphify extract ==="
  (
    cd "$repo"
    # Keep graphify-out/cache when resuming an interrupted run.
    if [[ ! -d graphify-out/cache ]]; then
      rm -rf graphify-out
    fi
    graphify extract . \
      --backend="$BACKEND" \
      --model="$MODEL" \
      --max-concurrency=1 \
      --api-timeout="$API_TIMEOUT" \
      --token-budget="$TOKEN_BUDGET"
    graphify hook install
  ) 2>&1 | tee "$log"
done

echo "All graphify runs complete. Logs in $LOG_DIR"
