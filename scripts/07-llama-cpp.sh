#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "07-llama-cpp"
export PATH="${HOME}/.local/bin:${PATH}"
bash "$EAI_ROOT/scripts/lib/install-build-tools.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export MY_IP=$(my_ip)

MODEL_PATH="${MODEL_PATH:-$HOME/models/gemma-4-26b-a4b-it-Q4_K_M.gguf}"
EAI_LLAMA_CPP_DIR="${EAI_LLAMA_CPP_DIR:-$EAI_BUILD_DIR/llama.cpp}"
EAI_LLAMA_CPP_BRANCH="${EAI_LLAMA_CPP_BRANCH:-gfx1151-rdna35-tuning}"
EAI_LLAMA_BACKEND="${EAI_LLAMA_BACKEND:-vulkan}"   # vulkan | hip
EAI_LLAMA_BUILD_HIP="${EAI_LLAMA_BUILD_HIP:-1}"     # also build HIP binary when 1

echo "=== 07-llama-cpp (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
echo "llama.cpp dir: $EAI_LLAMA_CPP_DIR branch: $EAI_LLAMA_CPP_BRANCH backend: $EAI_LLAMA_BACKEND"

ensure_git_repo https://github.com/ggml-org/llama.cpp.git "$EAI_LLAMA_CPP_DIR" "$EAI_LLAMA_CPP_BRANCH"
cd "$EAI_LLAMA_CPP_DIR"
log_source_tree "$EAI_LLAMA_CPP_DIR"

build_vulkan() {
  force_remove_cmake_build build-vulkan
  cmake -S . -B build-vulkan \
    -DGGML_VULKAN=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON
  cmake --build build-vulkan --config Release -j"$(nproc)"
  ./build-vulkan/bin/llama-cli --list-devices 2>&1 | head -25
}

build_hip() {
  if ! command -v hipcc &>/dev/null; then
    echo "WARN: hipcc not found — skip HIP build (install ROCm first: scripts/01-host-rocm.sh)"
    return 0
  fi
  force_remove_cmake_build build-hip
  cmake -S . -B build-hip \
    -DGGML_HIP=ON \
    -DAMDGPU_TARGETS=gfx1151 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DLLAMA_CURL=ON
  cmake --build build-hip --config Release -j"$(nproc)"
  ./build-hip/bin/llama-cli --list-devices 2>&1 | head -25 || true
}

build_vulkan
if [[ "$EAI_LLAMA_BUILD_HIP" == "1" ]]; then
  build_hip
fi

LLAMA_SERVER_BIN=""
LLAMA_BUILD_DIR=""
case "$EAI_LLAMA_BACKEND" in
  hip)
    LLAMA_BUILD_DIR="$EAI_LLAMA_CPP_DIR/build-hip"
    LLAMA_SERVER_BIN="$LLAMA_BUILD_DIR/bin/llama-server"
    ;;
  vulkan|*)
    LLAMA_BUILD_DIR="$EAI_LLAMA_CPP_DIR/build-vulkan"
    LLAMA_SERVER_BIN="$LLAMA_BUILD_DIR/bin/llama-server"
    ;;
esac

if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "ERROR: llama-server not found at $LLAMA_SERVER_BIN"
  exit 1
fi

systemctl --user stop llama-gemma.service 2>/dev/null || true

if [[ -f "$MODEL_PATH" ]]; then
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/llama-gemma.service << EOF
[Unit]
Description=llama.cpp server (Gemma 4) — ${EAI_LLAMA_BACKEND} backend
After=network.target

[Service]
Type=simple
WorkingDirectory=$EAI_LLAMA_CPP_DIR
Environment=HSA_OVERRIDE_GFX_VERSION=11.5.1
Environment=HSA_ENABLE_SDMA=0
Environment=MIOPEN_FIND_ENFORCE=1
Environment=PYTORCH_TUNABLEOP_ENABLED=1
Environment=TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
ExecStart=$LLAMA_SERVER_BIN \\
  --model ${MODEL_PATH} \\
  --n-gpu-layers 999 \\
  --ctx-size 32768 \\
  --flash-attn \\
  --host 0.0.0.0 \\
  --port 8080 \\
  --jinja \\
  --cache-type-k q8_0 \\
  --cache-type-v q8_0
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now llama-gemma.service
  sleep 5
  curl -sf http://localhost:8080/health && echo " llama-server healthy (${EAI_LLAMA_BACKEND})"

  kubectl delete aimmodel gemma-4-26b-a4b-local --ignore-not-found
  kubectl apply -f - << EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMModel
metadata:
  name: gemma-4-26b-a4b-local
  namespace: default
spec:
  displayName: "Gemma 4 26B-A4B (local Q4_K_M)"
  endpoint:
    url: "http://${MY_IP}:8080"
    type: OpenAI
  modelId: "gemma-4"
  capabilities:
    - chat
    - vision
EOF
else
  echo "Model not at ${MODEL_PATH} — binaries built; start server manually."
  echo "  Vulkan: $EAI_LLAMA_CPP_DIR/build-vulkan/bin/llama-server"
  echo "  HIP:    $EAI_LLAMA_CPP_DIR/build-hip/bin/llama-server (if built)"
fi

echo "Call flow: $EAI_ROOT/docs/call-flows/07-llama-cpp.md"
echo "gfx1151 guide: $EAI_ROOT/docs/gfx1151-upstream-pr-guide.md"
echo "Overview: $EAI_ROOT/docs/CALL_FLOW_OVERVIEW.md"
disk_report "07-llama-cpp-done"
activate_venv && pytest "$EAI_ROOT/tests/build/test_llama_cpp.py" -v --tb=short || true
