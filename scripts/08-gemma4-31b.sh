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
EAI_LLAMA_BACKEND="${EAI_LLAMA_BACKEND:-hip}"
LLAMA_PORT="${LLAMA31_PORT:-8081}"
AIM_NAMESPACE="${AIM_NAMESPACE:-demo}"
AIM_MODEL_NAME="${AIM_MODEL_NAME:-gemma-4-31b-local}"
AIM_SERVICE_NAME="${AIM_SERVICE_NAME:-gemma-4-31b-chat}"

echo "=== 08-gemma4-31b (local GGUF + AIMModel, namespace=${AIM_NAMESPACE}) ==="

if [[ ! -f "$GEMMA31_MODEL_PATH" ]]; then
  echo "ERROR: model not found at $GEMMA31_MODEL_PATH"
  echo "  ln -sf /path/to/google_gemma-4-31B-it-Q4_K_M.gguf $GEMMA31_MODEL_PATH"
  exit 1
fi
MODEL_SIZE=$(du -hL "$GEMMA31_MODEL_PATH" | awk '{print $1}')
echo "Model GGUF: $GEMMA31_MODEL_PATH ($MODEL_SIZE, no HF download)"

teardown_managed_hf_gemma() {
  echo "Removing managed HF Gemma 31B resources (if any)..."
  for ns in "$AIM_NAMESPACE" default; do
    kubectl delete aimservice "$AIM_SERVICE_NAME" -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      kubectl delete "$name" -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true
    done < <(kubectl get aimartifact,aimprofilecache,inferenceservice -n "$ns" -o name 2>/dev/null | grep -i gemma || true)
    if kubectl get pvc -n "$ns" -o name 2>/dev/null | grep -qi gemma; then
      echo "WARN: HF Gemma PVC still present in ${ns} (delete manually if Kyverno allows):"
      kubectl get pvc -n "$ns" 2>/dev/null | grep -i gemma || true
    fi
  done
  kubectl delete aimclusterprofile google-gemma-4-31b-r9700-latency --ignore-not-found --wait=false 2>/dev/null || true
}

teardown_managed_hf_gemma

# --- Host llama-server (existing GGUF, ~19 GiB) ---
LLAMA_SERVER_BIN=""
case "$EAI_LLAMA_BACKEND" in
  hip) LLAMA_SERVER_BIN="$EAI_LLAMA_CPP_DIR/build-hip/bin/llama-server" ;;
  *)   LLAMA_SERVER_BIN="$EAI_LLAMA_CPP_DIR/build-vulkan/bin/llama-server" ;;
esac

if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "ERROR: llama-server not found at $LLAMA_SERVER_BIN"
  echo "  EAI_LLAMA_BACKEND=hip bash scripts/07-llama-cpp.sh"
  exit 1
fi

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

echo "Waiting for llama-server on :${LLAMA_PORT}..."
for _ in $(seq 1 60); do
  curl -sf "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1 && break
  sleep 5
done
curl -sf "http://localhost:${LLAMA_PORT}/health" || {
  echo "ERROR: llama-server failed to start"
  journalctl --user -u llama-gemma-31b.service -n 30 --no-pager || true
  exit 1
}
echo " llama-server healthy (${EAI_LLAMA_BACKEND})"

# --- AIM registration: Service/Endpoints bridge + catalog AIMModel ---
if [[ "$AIM_NAMESPACE" != "default" ]]; then
  echo "Removing stale AIMModel registration from default (if any)..."
  kubectl delete aimmodel,svc,endpoints "${AIM_MODEL_NAME}" -n default --ignore-not-found --wait=false 2>/dev/null || true
fi

kubectl apply -f - << EOF
apiVersion: v1
kind: Service
metadata:
  name: ${AIM_MODEL_NAME}
  namespace: ${AIM_NAMESPACE}
  labels:
    app: ${AIM_MODEL_NAME}
spec:
  ports:
  - name: http
    port: ${LLAMA_PORT}
    targetPort: ${LLAMA_PORT}
---
apiVersion: v1
kind: Endpoints
metadata:
  name: ${AIM_MODEL_NAME}
  namespace: ${AIM_NAMESPACE}
subsets:
- addresses:
  - ip: ${MY_IP}
  ports:
  - name: http
    port: ${LLAMA_PORT}
EOF

kubectl apply -f - << EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMModel
metadata:
  name: ${AIM_MODEL_NAME}
  namespace: ${AIM_NAMESPACE}
  annotations:
    aim.eai.amd.com/external-endpoint: "http://${MY_IP}:${LLAMA_PORT}"
    aim.eai.amd.com/display-name: "Gemma 4 31B (local Q4_K_M)"
    aim.eai.amd.com/model-id: "gemma-4-31b"
spec:
  image: amdenterpriseai/aim-base:0.9
  discovery:
    extractMetadata: false
    createServiceTemplates: false
  imageMetadata:
    baseImageRef: docker.io/amdenterpriseai/aim-base:0.9
    model:
      canonicalName: google/gemma-4-31b-it
      hfTokenRequired: false
      tags:
        - text-generation
        - chat
        - instruction
      descriptionFull: >
        Gemma 4 31B instruction-tuned dense model served from local GGUF weights
        on gfx1151 (Strix Halo) via host llama-server.
EOF

echo "Waiting for AIMModel ${AIM_MODEL_NAME}..."
for _ in $(seq 1 30); do
  STATUS=$(kubectl get aimmodel "${AIM_MODEL_NAME}" -n "${AIM_NAMESPACE}" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  if [[ "$STATUS" == "Ready" ]]; then
    echo " AIMModel Ready"
    break
  fi
  sleep 2
done

kubectl get aimmodel "${AIM_MODEL_NAME}" -n "${AIM_NAMESPACE}" -o wide 2>/dev/null || true
kubectl get svc,endpoints "${AIM_MODEL_NAME}" -n "${AIM_NAMESPACE}" 2>/dev/null || true

echo ""
echo "Endpoint: http://${MY_IP}:${LLAMA_PORT}"
echo "In-cluster: http://${AIM_MODEL_NAME}.${AIM_NAMESPACE}.svc.cluster.local:${LLAMA_PORT}"
echo "AIMModel:   kubectl describe aimmodel ${AIM_MODEL_NAME} -n ${AIM_NAMESPACE}"
echo "Call flow:  $EAI_ROOT/docs/call-flows/08-gemma4-31b.md"
disk_report "08-gemma4-31b-done"
