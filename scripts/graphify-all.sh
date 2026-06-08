#!/usr/bin/env bash
# Build graphify knowledge graphs for amdeai and all eai-build repos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IGNORE_DIR="$SCRIPT_DIR/graphify-ignores"

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

# Ordered by increasing graphify complexity (~indexed source/doc files).
# ROCm study tree: ~/eai-build/rocm/* (see STACK_INDEX.md, fetch-study-sources.sh).
# cluster-forge is last (380 LLM chunks). llvm-project/rocm-systems are largest ROCm trees.
# Completed repos are skipped automatically.
ROCM="${HOME}/eai-build/rocm"
REPOS=(
  "/home/magnus/projects/amdeai"              # done — ~40 files
  "${HOME}/eai-build/aim-engine"              # done — ~700 files
  "${HOME}/eai-build/cert-manager"            # done — ~1000 files
  "${ROCM}/ROCm-Device-Libs"                  # ~1 file
  "${ROCM}/rocminfo"                          # ~15 files
  "${ROCM}/rocm_smi_lib"                      # ~85 files
  "${ROCM}/HIP"                               # ~90 files
  "${ROCM}/ROCm"                              # ~180 files
  "${HOME}/eai-build/k8s-device-plugin"       # ~50 files
  "${HOME}/eai-build/longhorn"                # ~300 files
  "${ROCM}/ROCR-Runtime"                      # ~530 files
  "${HOME}/eai-build/kaiwo"                   # ~500 files
  "${ROCM}/clr"                               # ~800 files
  "${HOME}/eai-build/k3s"                     # ~550 files
  "${HOME}/eai-build/metallb"                 # ~700 files
  "${HOME}/eai-build/kuberay"                 # ~900 files
  "${HOME}/eai-build/gateway-api"             # ~1400 files
  "${HOME}/eai-build/kueue"                   # ~2200 files
  "${HOME}/eai-build/kserve"                  # ~2200 files
  "${HOME}/eai-build/llama.cpp"               # ~1800 files
  "${ROCM}/rocm-systems"                      # ~2k files (scoped via graphifyignore)
  "${ROCM}/llvm-project"                      # ~1.7k files (scoped via graphifyignore)
  "${HOME}/eai-build/cluster-forge"           # ~700 files (scoped, latest chart versions) — last
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
    # Optional per-repo scope file (survives ~/eai-build refreshes).
    if [[ -f "$IGNORE_DIR/gen-${name}-ignore.py" ]]; then
      python3 "$IGNORE_DIR/gen-${name}-ignore.py" > .graphifyignore
      echo "[graphify] generated .graphifyignore via gen-${name}-ignore.py"
    elif [[ -f "$IGNORE_DIR/${name}.graphifyignore" ]]; then
      cp "$IGNORE_DIR/${name}.graphifyignore" .graphifyignore
      echo "[graphify] installed .graphifyignore from scripts/graphify-ignores/${name}.graphifyignore"
    fi
    # Rescope: wipe partial graph when ignore rules apply; else keep cache for resume.
    if [[ -f .graphifyignore && ! -f graphify-out/graph.json ]]; then
      rm -rf graphify-out
    elif [[ ! -d graphify-out/cache ]]; then
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
