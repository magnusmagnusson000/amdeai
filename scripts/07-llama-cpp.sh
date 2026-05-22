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

echo "=== 07-llama-cpp (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
fresh_git_clone https://github.com/ggml-org/llama.cpp.git "$EAI_BUILD_DIR/llama.cpp"
cd "$EAI_BUILD_DIR/llama.cpp"
log_source_tree "$EAI_BUILD_DIR/llama.cpp"

force_remove_cmake_build build-vulkan
cmake -S . -B build-vulkan \
  -DGGML_VULKAN=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON
cmake --build build-vulkan --config Release -j"$(nproc)"

./build-vulkan/bin/llama-cli --list-devices 2>&1 | head -25

systemctl --user stop llama-gemma.service 2>/dev/null || true

if [[ -f "$MODEL_PATH" ]]; then
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/llama-gemma.service << EOF
[Unit]
Description=llama.cpp Vulkan server (Gemma 4)
After=network.target

[Service]
Type=simple
WorkingDirectory=$EAI_BUILD_DIR/llama.cpp
ExecStart=$EAI_BUILD_DIR/llama.cpp/build-vulkan/bin/llama-server \\
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
  curl -sf http://localhost:8080/health && echo " llama-server healthy"

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
fi

echo "Call flow: $EAI_ROOT/docs/call-flows/07-llama-cpp.md"
echo "Overview: $EAI_ROOT/docs/CALL_FLOW_OVERVIEW.md"
disk_report "07-llama-cpp-done"
activate_venv && pytest "$EAI_ROOT/tests/build/test_llama_cpp.py" -v --tb=short || true
