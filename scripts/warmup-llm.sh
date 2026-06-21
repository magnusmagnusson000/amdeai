#!/usr/bin/env bash
# Warm up telecom LLM (vLLM / KServe predictor via stable bridge Service).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

LLM_BASE="${LLM_URL:-http://diffusiongemma-llm.default.svc.cluster.local}"
LLM_MODEL="${LLM_MODEL:-google/diffusiongemma-26B-A4B-it}"
LLM_ENABLE_THINKING="${LLM_ENABLE_THINKING:-true}"
TIMEOUT="${LLM_WARMUP_TIMEOUT:-180}"

base="${LLM_BASE%/}"
base="${base%/v1}"
url="${base}/v1/chat/completions"
models_url="${base}/v1/models"

warmup_payload="{\"model\":\"${LLM_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1,\"chat_template_kwargs\":{\"enable_thinking\":${LLM_ENABLE_THINKING}}}"

echo "Warming up LLM at ${url} (model=${LLM_MODEL}, timeout=${TIMEOUT}s)..."

if curl -sf "${models_url}" >/dev/null 2>&1; then
  :
elif command -v kubectl >/dev/null 2>&1; then
  echo "Host cannot reach cluster DNS; warming up via in-cluster curl pod..."
  kubectl run llm-warmup-once --rm -i --restart=Never --image=curlimages/curl:8.18.0 \
    -n "${LLM_WARMUP_NAMESPACE:-telecom-assistant}" -- \
    sh -c "curl -sf '${models_url}' && curl -sf --max-time ${TIMEOUT} -X POST '${url}' \
      -H 'Content-Type: application/json' -H 'Authorization: Bearer no-key-required' \
      -d '${warmup_payload}'"
  echo "LLM warmup complete."
  exit 0
else
  echo "ERROR: LLM models check failed at ${models_url}"
  exit 1
fi

curl -sf --max-time "$TIMEOUT" -X POST "$url" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer no-key-required" \
  -d "${warmup_payload}" \
  >/dev/null

echo "LLM warmup complete."
