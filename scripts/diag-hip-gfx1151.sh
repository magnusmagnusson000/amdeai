#!/usr/bin/env bash
# Deep HIP diagnostics for gfx1151 llama.cpp — kernel + verbose logs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export HSA_OVERRIDE_GFX_VERSION=11.5.1
export HSA_ENABLE_SDMA=0
export MIOPEN_FIND_ENFORCE=1
export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1

LLAMA_DIR="${EAI_LLAMA_CPP_DIR:-$EAI_BUILD_DIR/llama.cpp}"
BUILD="$LLAMA_DIR/build-hip"
LLAMA="$BUILD/bin/llama-cli"
PHI="${SLM_MODEL:-/home/magnus/projects/oracle/models/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf}"
LOG_DIR="${DIAG_LOG_DIR:-/tmp/hip-diag-$(date +%Y%m%d-%H%M%S)}"
TIMEOUT="${DIAG_TIMEOUT:-120}"

mkdir -p "$LOG_DIR"
echo "=== HIP diagnostics log dir: $LOG_DIR ==="

if pgrep -x ollama >/dev/null || pgrep -f "ollama runner" >/dev/null; then
  echo "ERROR: stop Ollama first: sudo systemctl stop ollama"
  exit 1
fi

{
  echo "=== System ==="
  date
  uname -r
  cat /proc/cmdline
  echo
  echo "=== ROCm ==="
  rocminfo 2>/dev/null | grep -E "Marketing|Name:|gfx" | head -12 || true
  rocm-smi --showmeminfo vram 2>/dev/null || true
  echo
  echo "=== DRM memory (bytes) ==="
  for f in mem_info_gtt_total mem_info_gtt_used mem_info_vram_total mem_info_vram_used; do
    printf "%s: " "$f"
    cat "/sys/class/drm/card1/device/$f" 2>/dev/null || echo "n/a"
  done
  echo
  echo "=== llama-cli ==="
  "$LLAMA" --version 2>&1 || true
  "$LLAMA" --list-devices 2>&1 || true
} | tee "$LOG_DIR/00-system.log"

dmesg_mark() {
  dmesg -T 2>/dev/null | tail -30 > "$LOG_DIR/dmesg-before-$1.log" || true
}

dmesg_after() {
  dmesg -T 2>/dev/null | tail -50 > "$LOG_DIR/dmesg-after-$1.log" || true
  dmesg -T 2>/dev/null | grep -iE 'amdgpu|kfd|page fault|PERMISSION|llama|gfxhub|SDMA' | tail -30 \
    > "$LOG_DIR/dmesg-filter-$1.log" || true
}

run_case() {
  local name="$1"
  shift
  echo
  echo "=== CASE: $name ==="
  dmesg_mark "$name"
  local out="$LOG_DIR/case-$name.out"
  local err="$LOG_DIR/case-$name.err"
  set +e
  timeout "$TIMEOUT" "$@" >"$out" 2>"$err"
  local rc=$?
  set -e
  dmesg_after "$name"
  echo "exit=$rc (timeout=124 means hung)"
  tail -20 "$out" 2>/dev/null || true
  if [[ -s "$err" ]]; then
    echo "--- stderr tail ---"
    tail -15 "$err"
  fi
  pkill -9 -f llama-cli 2>/dev/null || true
  sleep 2
  return 0
}

run_case "cpu-ngl0" "$LLAMA" -m "$PHI" -ngl 0 -c 256 -n 4 \
  -p "2+2=" --no-display-prompt --simple-io -fa 0

run_case "gpu-ngl1" "$LLAMA" -m "$PHI" -ngl 1 -c 256 -n 4 \
  -p "2+2=" --no-display-prompt --simple-io -fa 0

run_case "gpu-ngl99" "$LLAMA" -m "$PHI" -ngl 99 -c 512 -n 8 \
  -p "What is 2+2?" --no-display-prompt --simple-io -fa 0

run_case "gpu-ngl99-verbose" "$LLAMA" -m "$PHI" -ngl 99 -c 256 -n 2 \
  -p "Hi" --no-display-prompt --simple-io -fa 0 -v 2>&1

run_case "gpu-no-fusion" env GGML_CUDA_DISABLE_FUSION=1 GGML_CUDA_DISABLE_GRAPHS=1 \
  "$LLAMA" -m "$PHI" -ngl 99 -c 256 -n 4 \
  -p "2+2=" --no-display-prompt --simple-io -fa 0

echo
echo "=== Summary ==="
for f in "$LOG_DIR"/case-*.out; do
  base=$(basename "$f" .out)
  rc=$(grep -o 'exit=[0-9]*' "$LOG_DIR/${base/out/}" 2>/dev/null || true)
  last=$(tail -1 "$f" 2>/dev/null | head -c 80)
  echo "$base: ${last:-empty}"
done
echo "Full logs: $LOG_DIR"
ls -la "$LOG_DIR"
