#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "08-gemma4-31b"
export PATH="${HOME}/.local/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export MY_IP=$(my_ip)

GEMMA31_MODEL_PATH="${GEMMA31_MODEL_PATH:-$HOME/models/gemma-4-31b-it-Q4_K_M.gguf}"
EAI_LLAMA_CPP_DIR="${EAI_LLAMA_CPP_DIR:-$EAI_BUILD_DIR/llama.cpp}"
EAI_LLAMA_BACKEND="${EAI_LLAMA_BACKEND:-vulkan}"   # vulkan | hip
LLAMA_PORT="${LLAMA31_PORT:-8081}"

echo "=== 08-gemma4-31b (backend=${EAI_LLAMA_BACKEND}, port=${LLAMA_PORT}) ==="
echo "Model: $GEMMA31_MODEL_PATH"
echo "llama.cpp dir: $EAI_LLAMA_CPP_DIR"

LLAMA_SERVER_BIN=""
case "$EAI_LLAMA_BACKEND" in
  hip)
    LLAMA_SERVER_BIN="$EAI_LLAMA_CPP_DIR/build-hip/bin/llama-server"
    ;;
  vulkan|*)
    LLAMA_SERVER_BIN="$EAI_LLAMA_CPP_DIR/build-vulkan/bin/llama-server"
    ;;
esac

if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "ERROR: llama-server not found at $LLAMA_SERVER_BIN"
  echo "Run scripts/07-llama-cpp.sh first to build llama.cpp binaries."
  exit 1
fi

if [[ ! -f "$GEMMA31_MODEL_PATH" ]]; then
  echo "ERROR: model not found at $GEMMA31_MODEL_PATH"
  echo "Download or symlink the GGUF, e.g.:"
  echo "  mkdir -p ~/models"
  echo "  ln -sf /path/to/google_gemma-4-31B-it-Q4_K_M.gguf ~/models/gemma-4-31b-it-Q4_K_M.gguf"
  exit 1
fi

MODEL_SIZE=$(du -hL "$GEMMA31_MODEL_PATH" | awk '{print $1}')
echo "Model size: $MODEL_SIZE"

systemctl --user stop llama-gemma-31b.service 2>/dev/null || true

mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/llama-gemma-31b.service << EOF
[Unit]
Description=llama.cpp server (Gemma 4 31B) — ${EAI_LLAMA_BACKEND} backend
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
  --model ${GEMMA31_MODEL_PATH} \\
  --n-gpu-layers 999 \\
  --ctx-size 32768 \\
  --flash-attn on \\
  --host 0.0.0.0 \\
  --port ${LLAMA_PORT} \\
  --jinja \\
  --cache-type-k q8_0 \\
  --cache-type-v q8_0
Restart=on-failure

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now llama-gemma-31b.service

echo "Waiting for llama-server on port ${LLAMA_PORT}..."
for _ in $(seq 1 60); do
  if curl -sf "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1; then
    echo " llama-server healthy (${EAI_LLAMA_BACKEND})"
    break
  fi
  sleep 5
done

if ! curl -sf "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1; then
  echo "ERROR: llama-server did not become healthy on port ${LLAMA_PORT}"
  systemctl --user status llama-gemma-31b.service --no-pager || true
  journalctl --user -u llama-gemma-31b.service -n 40 --no-pager || true
  exit 1
fi

kubectl delete aimmodel gemma-4-31b-local --ignore-not-found
kubectl delete service gemma-4-31b-local --ignore-not-found
kubectl delete endpoints gemma-4-31b-local --ignore-not-found

# Cluster Service + Endpoints bridge host llama-server to in-cluster consumers (AIWB pods).
kubectl apply -f - << EOF
apiVersion: v1
kind: Service
metadata:
  name: gemma-4-31b-local
  namespace: default
  labels:
    app: gemma-4-31b-local
spec:
  ports:
  - name: http
    port: ${LLAMA_PORT}
    targetPort: ${LLAMA_PORT}
---
apiVersion: v1
kind: Endpoints
metadata:
  name: gemma-4-31b-local
  namespace: default
subsets:
- addresses:
  - ip: ${MY_IP}
  ports:
  - name: http
    port: ${LLAMA_PORT}
EOF

# AIM Engine v0.2.x removed spec.endpoint/displayName/capabilities on AIMModel.
# Register a catalog stub with external-endpoint annotation + in-cluster Service bridge.
kubectl apply -f - << EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMModel
metadata:
  name: gemma-4-31b-local
  namespace: default
  annotations:
    aim.eai.amd.com/external-endpoint: "http://${MY_IP}:${LLAMA_PORT}"
    aim.eai.amd.com/display-name: "Gemma 4 31B (local Q4_K_M)"
    aim.eai.amd.com/model-id: "gemma-4-31b"
spec:
  image: amdenterpriseai/aim-base:0.11.0
  discovery:
    extractMetadata: false
    createServiceTemplates: false
EOF

echo "AIMModel gemma-4-31b-local registered at http://${MY_IP}:${LLAMA_PORT}"
echo "Call flow: $EAI_ROOT/docs/call-flows/08-gemma4-31b.md"
echo "Overview: $EAI_ROOT/docs/CALL_FLOW_OVERVIEW.md"
disk_report "08-gemma4-31b-done"
