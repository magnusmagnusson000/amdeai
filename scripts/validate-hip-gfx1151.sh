#!/usr/bin/env bash
# Validate llama.cpp HIP on gfx1151 after gfx1151-rdna35-tuning merge.
# Prerequisite: stop GPU consumers (Ollama, other llama-server instances).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export HSA_OVERRIDE_GFX_VERSION=11.5.1
export HSA_ENABLE_SDMA=0
export MIOPEN_FIND_ENFORCE=1

LLAMA_DIR="${EAI_LLAMA_CPP_DIR:-$EAI_BUILD_DIR/llama.cpp}"
BUILD="$LLAMA_DIR/build-hip"
# Phi-4-mini: dense SLM without Qwen3.5 Gated Delta Net (avoids graph-reserve hang on gfx1151).
SLM="${SLM_MODEL:-/home/magnus/projects/oracle/models/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf}"
GEMMA="${GEMMA_MODEL:-/home/magnus/projects/oracle/models/gemma-4-26b-a4b-it-Q4_K_M.gguf}"

if pgrep -x ollama >/dev/null || pgrep -f "ollama runner" >/dev/null; then
  echo "ERROR: Ollama is running and may block the GPU. Stop it first:"
  echo "  sudo systemctl stop ollama"
  exit 1
fi

if [[ ! -x "$BUILD/bin/llama-cli" ]]; then
  echo "ERROR: HIP build not found. Run: EAI_LLAMA_BUILD_HIP=1 bash scripts/07-llama-cpp.sh"
  exit 1
fi

if modinfo amdgpu 2>/dev/null | grep -q '/updates/dkms/'; then
  echo "ERROR: DKMS amdgpu is loaded — breaks gfx1151 HIP (PERMISSION_FAULT page faults)."
  echo "  sudo apt remove -y amdgpu-dkms amdgpu-dkms-firmware"
  echo "  sudo apt install -y linux-oem-24.04d && sudo reboot"
  exit 1
fi

echo "=== Device ==="
"$BUILD/bin/llama-cli" --list-devices

echo "=== SLM test (dense): $SLM ==="
"$BUILD/bin/llama-cli" -m "$SLM" -ngl 99 -c 2048 -n 16 \
  -p "What is 2+2? Answer briefly." --no-display-prompt --simple-io -fa 0 --single-turn

if [[ -f "$GEMMA" ]]; then
  echo "=== Gemma 4 MoE test (HIP): $GEMMA ==="
  OUT=$("$BUILD/bin/llama-cli" -m "$GEMMA" -ngl 99 -c 4096 -n 32 \
    -p "Hello, introduce yourself in one sentence." --no-display-prompt --simple-io -fa 0 --single-turn 2>&1) || true
  echo "$OUT"
  if echo "$OUT" | grep -q '<unused'; then
    echo "FAIL: MoE router still emitting <unused> tokens — see docs/gfx1151-upstream-pr-guide.md"
    exit 2
  fi
  echo "PASS: No <unused> token repeat detected in Gemma 4 HIP output"
else
  echo "SKIP Gemma test — model not at $GEMMA"
fi

echo "=== Done ==="
