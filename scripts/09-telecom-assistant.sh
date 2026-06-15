#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "09-telecom-assistant"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export MY_IP=$(my_ip)

TELECOM_REPO="${TELECOM_REPO:-$EAI_BUILD_DIR/solution-blueprints/solution-blueprints/telecom-assistant}"
TELECOM_NAMESPACE="${TELECOM_NAMESPACE:-telecom-assistant}"
TELECOM_RELEASE="${TELECOM_RELEASE:-eai-telecom}"
VALUES_FILE="${TELECOM_VALUES:-$EAI_ROOT/manifests/telecom-assistant/values-eai-local.yaml}"
FRONTEND_LIVEKIT_URL="${FRONTEND_LIVEKIT_URL:-ws://localhost:7880}"
INSTALL_STUNNER="${INSTALL_STUNNER:-1}"

echo "=== 09-telecom-assistant (namespace=${TELECOM_NAMESPACE}, release=${TELECOM_RELEASE}) ==="

if [[ ! -d "$TELECOM_REPO" ]]; then
  echo "Cloning solution-blueprints..."
  fresh_git_clone https://github.com/amd-enterprise-ai/solution-blueprints.git "$EAI_BUILD_DIR/solution-blueprints"
fi

if [[ ! -f "$VALUES_FILE" ]]; then
  echo "ERROR: values file not found: $VALUES_FILE"
  exit 1
fi

if [[ "$INSTALL_STUNNER" == "1" ]]; then
  if kubectl get deployment stunner-gateway-operator-controller-manager -n stunner-system &>/dev/null; then
    echo "STUNner operator already installed (stunner-system); skipping install-prerequisites.sh"
  else
    echo "Installing STUNner operator (once per cluster)..."
    bash "$TELECOM_REPO/install-prerequisites.sh"
  fi
else
  echo "Skipping STUNner install (INSTALL_STUNNER=0)"
fi

echo "Building Helm dependencies..."
helm repo add livekit https://helm.livekit.io 2>/dev/null || true
helm repo add stunner https://l7mp.io/stunner 2>/dev/null || true
helm repo update livekit stunner >/dev/null
cd "$TELECOM_REPO"
helm dependency build

kubectl create namespace "$TELECOM_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

CTR="sudo /var/lib/rancher/rke2/bin/ctr --address /run/k3s/containerd/containerd.sock --namespace k8s.io"
# Set TELECOM_SKIP_BUILD=1 to skip all local image rebuilds on redeploy.
_skip="${TELECOM_SKIP_BUILD:-0}"
BUILD_CPU_SPEECH="${BUILD_CPU_SPEECH:-$([ "$_skip" == "1" ] && echo 0 || echo 1)}"
BUILD_TELECOM_FRONTEND="${BUILD_TELECOM_FRONTEND:-$([ "$_skip" == "1" ] && echo 0 || echo 1)}"
BUILD_BSSGATEWAY="${BUILD_BSSGATEWAY:-$([ "$_skip" == "1" ] && echo 0 || echo 1)}"
BUILD_TELECOM_AGENT="${BUILD_TELECOM_AGENT:-0}"

if [[ "$BUILD_CPU_SPEECH" == "1" ]]; then
  echo "Building CPU STT/TTS images..."
  docker build -t telecom-stt-service:local "$EAI_ROOT/services/stt-service/"
  docker build -t telecom-tts-service:local "$EAI_ROOT/services/tts-service/"

  echo "Importing images into RKE2 containerd..."
  docker save telecom-stt-service:local | $CTR images import -
  docker save telecom-tts-service:local | $CTR images import -
fi

if [[ "$BUILD_TELECOM_FRONTEND" == "1" ]]; then
  echo "Building patched frontend image (LLM page-load warmup + LiveKit WS proxy)..."
  docker build -t telecom-frontend:local "$EAI_ROOT/services/telecom-frontend/"
  docker save telecom-frontend:local | $CTR images import -
fi

if [[ "$BUILD_BSSGATEWAY" == "1" ]]; then
  echo "Building local BSSGateway image (reuses STT base; avoids Docker Hub rate limits)..."
  docker build -t telecom-bssgateway:local "$EAI_ROOT/services/telecom-bssgateway/"
  docker save telecom-bssgateway:local | $CTR images import -
fi

if [[ "$BUILD_TELECOM_AGENT" == "1" ]]; then
  echo "Building local agent image (GHCR uv base; avoids Docker Hub rate limits)..."
  docker build -f "$TELECOM_REPO/docker/agent.Dockerfile" -t telecom-agent:local "$TELECOM_REPO"
  docker save telecom-agent:local | $CTR images import -
fi

echo "Ensuring Qwen LLM bridge (Workbench catalog Deploy or scripts/10)..."
bash "$EAI_ROOT/scripts/ensure-qwen-tool-calling.sh" "${QWEN_AIM_NAMESPACE:-demo}" || \
  echo "WARN: Qwen tool-calling setup skipped (is AIM predictor Running?)"
QWEN_BRIDGE_WAIT="${QWEN_BRIDGE_WAIT:-300}" bash "$EAI_ROOT/scripts/ensure-qwen-llm-bridge.sh"
kubectl apply -f "$EAI_ROOT/manifests/telecom-assistant/stt-deployment.yaml" -n "$TELECOM_NAMESPACE"
kubectl apply -f "$EAI_ROOT/manifests/telecom-assistant/tts-deployment.yaml" -n "$TELECOM_NAMESPACE"
kubectl delete cronjob gemma-warmup -n "$TELECOM_NAMESPACE" --ignore-not-found
kubectl apply -f "$EAI_ROOT/manifests/telecom-assistant/llm-warmup-cronjob.yaml" -n "$TELECOM_NAMESPACE"

echo "Rendering and applying chart..."
helm template "$TELECOM_RELEASE" . \
  --namespace "$TELECOM_NAMESPACE" \
  -f "$VALUES_FILE" \
  --set "mainServices.frontend.env.LIVEKIT_URL=${FRONTEND_LIVEKIT_URL}" \
  | kubectl apply -f - -n "$TELECOM_NAMESPACE"

echo "Patching agent with ConfigMap (LLM timeout, warmup, error handling)..."
bash "$EAI_ROOT/scripts/patch-telecom-agent.sh"

echo ""
echo "Waiting for CPU speech services..."
kubectl rollout status deployment/telecom-stt -n "$TELECOM_NAMESPACE" --timeout=900s 2>/dev/null || true
kubectl rollout status deployment/telecom-tts -n "$TELECOM_NAMESPACE" --timeout=900s 2>/dev/null || true

echo ""
echo "Waiting for core pods..."
kubectl wait --for=condition=available deployment \
  -l "app.kubernetes.io/instance=${TELECOM_RELEASE}" \
  -n "$TELECOM_NAMESPACE" \
  --timeout=600s 2>/dev/null || true

kubectl get pods,svc -n "$TELECOM_NAMESPACE"

echo ""
echo "Warming up Qwen3.6-27B AIM..."
bash "$EAI_ROOT/scripts/warmup-llm.sh" || echo "WARN: LLM warmup skipped (is AIMService qwen3-6-27b Running?)"

echo ""
echo "Port-forward (separate terminals):"
echo "  kubectl port-forward svc/aimsb-telecom-assistant-${TELECOM_RELEASE}-frontend 3000:3000 -n ${TELECOM_NAMESPACE}"
echo "  kubectl port-forward svc/${TELECOM_RELEASE}-livekit 7880:7880 -n ${TELECOM_NAMESPACE}"
echo "  open http://localhost:3000"
echo ""
echo "Run tests:"
echo "  pytest tests/integration/test_telecom_assistant.py -v"
echo "  E2E_TELECOM=1 pytest tests/e2e/test_telecom_assistant.py -v"
echo "  E2E_TELECOM=1 E2E_TELECOM_AGENT=1 pytest tests/e2e/test_telecom_assistant.py::test_text_chat_milkyway_passphrase -v"
echo "Call flow: $EAI_ROOT/docs/call-flows/09-telecom-assistant.md"
echo "Speech manual: $EAI_ROOT/docs/TELECOM_ASSISTANT_SPEECH_TESTING.md"
disk_report "09-telecom-assistant-done"
