#!/usr/bin/env bash
# Warm up Gemma 4 llama-server (loads graphs / primes inference path).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

GEMMA_URL="${GEMMA_URL:-http://localhost:8081}"
GEMMA_MODEL="${GEMMA_MODEL:-gemma-4-31b}"
TIMEOUT="${GEMMA_WARMUP_TIMEOUT:-180}"

base="${GEMMA_URL%/}"
url="${base}/v1/chat/completions"

echo "Warming up Gemma at ${url} (model=${GEMMA_MODEL}, timeout=${TIMEOUT}s)..."
curl -sf "${base}/health" >/dev/null || {
  echo "ERROR: Gemma health check failed at ${base}/health"
  exit 1
}

curl -sf --max-time "$TIMEOUT" -X POST "$url" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer no-key-required" \
  -d "{\"model\":\"${GEMMA_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
  >/dev/null

echo "Gemma warmup complete."
