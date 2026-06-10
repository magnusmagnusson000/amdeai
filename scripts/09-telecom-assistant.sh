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
  echo "Installing STUNner operator (once per cluster)..."
  bash "$TELECOM_REPO/install-prerequisites.sh"
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

echo "Rendering and applying chart..."
helm template "$TELECOM_RELEASE" . \
  --namespace "$TELECOM_NAMESPACE" \
  -f "$VALUES_FILE" \
  --set "mainServices.frontend.env.LIVEKIT_URL=${FRONTEND_LIVEKIT_URL}" \
  | kubectl apply -f - -n "$TELECOM_NAMESPACE"

if [[ "${GFX1151_SINGLE_GPU:-1}" == "1" ]]; then
  echo "Applying gfx1151 single-GPU agent init patch..."
  bash "$EAI_ROOT/manifests/telecom-assistant/patch-agent-init-gfx1151.sh"
fi

echo ""
echo "Waiting for core pods..."
kubectl wait --for=condition=available deployment \
  -l "app.kubernetes.io/instance=${TELECOM_RELEASE}" \
  -n "$TELECOM_NAMESPACE" \
  --timeout=600s 2>/dev/null || true

kubectl get pods,svc -n "$TELECOM_NAMESPACE"
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
