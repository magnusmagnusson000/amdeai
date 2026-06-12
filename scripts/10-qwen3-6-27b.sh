#!/usr/bin/env bash
# Deploy Qwen/Qwen3.6-27B (27B BF16) on gfx1151 via AIM Engine + plain K8s Deployment.
#
# WHY NOT AIMService for inference?
#   amdenterpriseai/aim-base:0.11 uses a PyTorch build that lacks compiled gfx1151
#   kernels — torch.randn(..., device='cuda') segfaults on Strix Halo.
#
# ACTUAL APPROACH (3-layer hybrid):
#   Layer 1 — AIM catalog:
#     AIMClusterModel  qwen-qwen3-6-27b
#     AIMClusterProfile qwen3-6-27b-r9700-gfx1151-latency
#   Layer 2 — Weight download:
#     AIMService qwen3-6-27b → AIMArtifact download job (~55.6 GiB from hf://Qwen/Qwen3.6-27B)
#   Layer 3 — Inference:
#     Plain K8s Deployment using kyuz0/vllm-therock-gfx1151:stable
#     AIMModel qwen3-6-27b-vllm registers it in AI Workbench
#
# Endpoint: http://<NODE_IP>:30401/v1  (NodePort 30401 → qwen3-6-27b-vllm:8000)
#
# Prerequisites:
#   - AIM Engine operator running (kubectl get crd aimservices.aim.eai.amd.com)
#   - scripts/03b-gfx1151-aim-labels.sh applied (R9700 accelerator label on node)
#   - ~60 GiB free disk space for weights PVC
#
# Usage:
#   bash scripts/10-qwen3-6-27b.sh
#   AIM_NAMESPACE=default bash scripts/10-qwen3-6-27b.sh
#
# See: docs/GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
AIM_NAMESPACE="${AIM_NAMESPACE:-default}"
PROFILE_NAME="qwen3-6-27b-r9700-gfx1151-latency"
SERVICE_NAME="qwen3-6-27b"
MODEL_NAME="qwen-qwen3-6-27b"
MANIFEST_DIR="$EAI_ROOT/manifests/aim/qwen3-6-27b"
NODE_PORT=30401
NODE_IP="$(my_ip)"

PROFILE_READY_TIMEOUT=120
DOWNLOAD_TIMEOUT=3600       # 60 min — ~55.6 GiB
POD_READY_TIMEOUT=1800      # 30 min — large model load + vLLM startup

echo "=== 10-qwen3-6-27b (namespace=${AIM_NAMESPACE}) ==="

# --- Disk guard (need ~60 GiB for weights PVC) ---
EAI_MIN_FREE_GB=60 check_disk_before_step "10-qwen3-6-27b"
disk_report "10-qwen3-6-27b-start"

# --- Step 1: Ensure R9700 accelerator label is on node ---
echo ""
echo "--- Step 1: R9700 accelerator label ---"
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
if kubectl get node "${NODE}" --show-labels 2>/dev/null | grep -q 'aim-accelerator.R9700'; then
  echo "R9700 label already present on ${NODE}."
else
  echo "Applying gfx1151 AIM accelerator labels (03b-gfx1151-aim-labels.sh)..."
  bash "$SCRIPT_DIR/03b-gfx1151-aim-labels.sh"
fi

# --- Step 2: Apply AIMClusterModel (catalog entry) ---
echo ""
echo "--- Step 2: AIMClusterModel ---"
kubectl apply -f "${MANIFEST_DIR}/aim-clustermodel.yaml"
kubectl get aimclustermodel "${MODEL_NAME}" 2>/dev/null || true

# --- Step 3: Apply AIMClusterProfile (runtime config) ---
echo ""
echo "--- Step 3: AIMClusterProfile ---"
kubectl apply -f "${MANIFEST_DIR}/aim-clusterprofile.yaml"

echo "Waiting for AIMClusterProfile to become Ready (up to ${PROFILE_READY_TIMEOUT}s)..."
ELAPSED=0
while [[ $ELAPSED -lt $PROFILE_READY_TIMEOUT ]]; do
  PSTATUS=$(kubectl get aimclusterprofile "${PROFILE_NAME}" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  echo "  profile status: ${PSTATUS:-pending} (${ELAPSED}s)"
  case "$PSTATUS" in
    Ready) echo "Profile is Ready."; break ;;
    NotAvailable)
      echo "ERROR: Profile NotAvailable — no node matches acceleratorModel=R9700."
      echo "  Run: bash scripts/03b-gfx1151-aim-labels.sh"
      kubectl get aimclusterprofile "${PROFILE_NAME}" -o yaml 2>/dev/null | grep -A10 'status:' || true
      exit 1
      ;;
  esac
  sleep 10; ELAPSED=$((ELAPSED + 10))
done

# --- Step 3b: AIMClusterServiceTemplate (enables AI Workbench catalog Deploy) ---
echo ""
echo "--- Step 3b: AIMClusterServiceTemplate ---"
kubectl apply -f "${MANIFEST_DIR}/aim-clusterservicetemplate.yaml"
for _ in $(seq 1 30); do
  TSTATUS=$(kubectl get aimclusterservicetemplate qwen3-6-27b-r9700-gfx1151-latency \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  echo "  template status: ${TSTATUS:-pending}"
  [[ "$TSTATUS" == "Ready" ]] && break
  sleep 5
done

# --- Step 4: Apply AIMService to trigger weight download ---
echo ""
echo "--- Step 4: AIMService (weight download only) ---"
echo "NOTE: The InferenceService pod will crash (aim-base:0.11 lacks gfx1151 kernels)."
echo "      We only need the AIMArtifact PVC. The actual serving uses kyuz0 image below."
kubectl apply -f "${MANIFEST_DIR}/aim-service.yaml"

# --- Step 5: Wait for AIMArtifact PVC to be populated ---
echo ""
echo "--- Step 5: Waiting for weights download (up to ${DOWNLOAD_TIMEOUT}s) ---"
ELAPSED=0
PVC_NAME=""
while [[ $ELAPSED -lt $DOWNLOAD_TIMEOUT ]]; do
  PVC_NAME=$(kubectl get pvc -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -i "qwen.*3.*6\|qwen3-6-27b" | awk '{print $1}' | head -1 || true)
  ART_NAME=$(kubectl get aimartifact -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
    | grep -i "qwen" | head -1 || true)

  if [[ -n "$ART_NAME" ]]; then
    ART_STATUS=$(kubectl get "$ART_NAME" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  ART_PROGRESS=$(kubectl get "$ART_NAME" -n "${AIM_NAMESPACE}" \
    -o jsonpath='{.status.progress}' 2>/dev/null || echo "")
    echo "  artifact: ${ART_NAME##*/} status=${ART_STATUS:-unknown} progress=${ART_PROGRESS:-?}% pvc=${PVC_NAME:-none} (${ELAPSED}s)"
    case "$ART_STATUS" in
      Succeeded|Ready) echo "Download complete. PVC: ${PVC_NAME}"; break ;;
      Failed)
        echo "ERROR: AIMArtifact download failed."
        kubectl get "$ART_NAME" -n "${AIM_NAMESPACE}" -o yaml 2>/dev/null || true
        exit 1
        ;;
    esac
  elif [[ -n "$PVC_NAME" ]]; then
    PVC_PHASE=$(kubectl get pvc "$PVC_NAME" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    echo "  pvc=${PVC_NAME} phase=${PVC_PHASE} (${ELAPSED}s) — artifact CR not yet found"
    [[ "$PVC_PHASE" == "Bound" ]] && {
      echo "PVC is Bound. Waiting for artifact Ready status..."
    }
  else
    SVCSTATUS=$(kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    echo "  aimservice status=${SVCSTATUS:-pending}, searching for PVC (${ELAPSED}s)"
  fi
  sleep 30; ELAPSED=$((ELAPSED + 30))
done

if [[ -z "$PVC_NAME" ]]; then
  echo "ERROR: No weights PVC found after ${DOWNLOAD_TIMEOUT}s."
  echo "  Check: kubectl get aimartifact -n ${AIM_NAMESPACE}"
  echo "  Check: kubectl get pvc -n ${AIM_NAMESPACE}"
  exit 1
fi

echo "Using weights PVC: ${PVC_NAME}"

# --- Step 6: Scale down the failing AIMService pod (keep resources) ---
echo ""
echo "--- Step 6: Pause AIMService pod (weights PVC will remain) ---"
ISVC_NAME=$(kubectl get inferenceservice -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
  | grep -i "qwen3\|qwen-3" | awk '{print $1}' | head -1 || true)
if [[ -n "$ISVC_NAME" ]]; then
  echo "Scaling down InferenceService ${ISVC_NAME} replicas to 0..."
  kubectl patch inferenceservice "${ISVC_NAME}" -n "${AIM_NAMESPACE}" \
    --type='json' -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0}]' \
    2>/dev/null || \
  kubectl scale deployment -n "${AIM_NAMESPACE}" \
    -l "serving.kserve.io/inferenceservice=${ISVC_NAME}" --replicas=0 2>/dev/null || \
  kubectl scale replicaset -n "${AIM_NAMESPACE}" \
    -l "serving.kserve.io/inferenceservice=${ISVC_NAME}" --replicas=0 2>/dev/null || true
fi

# --- Step 7: Update deployment manifest with correct PVC name and deploy ---
echo ""
echo "--- Step 7: Deploy qwen3-6-27b-vllm (kyuz0/vllm-therock-gfx1151:stable) ---"

DEPLOY_MANIFEST="${MANIFEST_DIR}/qwen3-6-27b-deployment.yaml"
PLACEHOLDER_PVC="hf---qwen-qwen3-6-27b-PLACEHOLDER-cache-PLACEHOLDER"
if [[ "$PVC_NAME" != "$PLACEHOLDER_PVC" ]]; then
  echo "  Patching PVC name: ${PLACEHOLDER_PVC} → ${PVC_NAME}"
  sed -i "s|claimName: ${PLACEHOLDER_PVC}|claimName: ${PVC_NAME}|g" "$DEPLOY_MANIFEST"
fi

kubectl apply -f "$DEPLOY_MANIFEST"

echo "Waiting for qwen3-6-27b-vllm pod to become Ready (up to ${POD_READY_TIMEOUT}s)..."
echo "(27B model load may take 10–20 min on first run)"
ELAPSED=0
while [[ $ELAPSED -lt $POD_READY_TIMEOUT ]]; do
  POD_STATUS=$(kubectl get pods -n "${AIM_NAMESPACE}" -l app=qwen3-6-27b-vllm \
    --no-headers 2>/dev/null | head -1 || true)
  READY=$(echo "$POD_STATUS" | awk '{print $2}')
  STATUS=$(echo "$POD_STATUS" | awk '{print $3}')
  echo "  pod: ${READY:-0/1} ${STATUS:-unknown} (${ELAPSED}s)"
  [[ "$READY" == "1/1" ]] && { echo "Pod is Ready!"; break; }
  case "$STATUS" in
    CrashLoopBackOff|Error|OOMKilled)
      POD_NAME=$(echo "$POD_STATUS" | awk '{print $1}')
      echo "ERROR: Pod crashed. Logs:"
      kubectl logs "$POD_NAME" -n "${AIM_NAMESPACE}" --tail=50 2>/dev/null || true
      exit 1
      ;;
  esac
  sleep 30; ELAPSED=$((ELAPSED + 30))
done

if [[ "$(kubectl get pods -n "${AIM_NAMESPACE}" -l app=qwen3-6-27b-vllm \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)" != "true" ]]; then
  echo "WARNING: Pod not Ready after ${POD_READY_TIMEOUT}s. May still be starting."
  echo "  Monitor: kubectl logs -n ${AIM_NAMESPACE} -l app=qwen3-6-27b-vllm -f"
fi

# --- Step 8: Register in AI Workbench via AIMModel ---
echo ""
echo "--- Step 8: AIMModel (AI Workbench registration) ---"
AIMMODEL_MANIFEST="${MANIFEST_DIR}/qwen3-6-27b-aimmodel.yaml"
# Patch external-endpoint with current node IP
sed -i "s|aim.eai.amd.com/external-endpoint: http://[0-9.]*:${NODE_PORT}|aim.eai.amd.com/external-endpoint: http://${NODE_IP}:${NODE_PORT}|g" \
  "$AIMMODEL_MANIFEST"
kubectl apply -f "$AIMMODEL_MANIFEST"
echo "AIMModel qwen3-6-27b-vllm registered."

# --- Step 9: E2E smoke tests ---
echo ""
echo "=== E2E Smoke Tests (endpoint: http://${NODE_IP}:${NODE_PORT}/v1) ==="

ENDPOINT="http://${NODE_IP}:${NODE_PORT}"

echo ""
echo "--- Test 1: GET /health ---"
curl -sf --max-time 30 "${ENDPOINT}/health" && echo " OK" \
  || echo "WARN: health check failed (pod may still be loading)"

echo ""
echo "--- Test 2: GET /v1/models ---"
curl -sf --max-time 60 "${ENDPOINT}/v1/models" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Models:', [m['id'] for m in d['data']])" \
  2>/dev/null \
  || curl -s --max-time 60 "${ENDPOINT}/v1/models" | head -200

echo ""
echo "--- Test 3: POST /v1/chat/completions (thinking disabled) ---"
curl -sf --max-time 120 -X POST "${ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3.6-27B","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":10,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Response:', d['choices'][0]['message']['content'])" \
  2>/dev/null \
  || curl -s --max-time 120 -X POST "${ENDPOINT}/v1/chat/completions" \
     -H "Content-Type: application/json" \
     -d '{"model":"Qwen/Qwen3.6-27B","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":10,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}'

echo ""
echo "=== Summary ==="
echo "Model:    Qwen/Qwen3.6-27B (27B, bf16)"
echo "Engine:   vLLM (kyuz0/vllm-therock-gfx1151:stable — TheRock nightly ROCm, gfx1151)"
echo "AIM:      AIMClusterModel + AIMClusterProfile (${PROFILE_NAME})"
echo "Service:  qwen3-6-27b-vllm (NodePort ${NODE_PORT})"
echo "AIMModel: qwen3-6-27b-vllm (AI Workbench registration)"
echo ""
echo "Endpoint:  ${ENDPOINT}/v1"
echo ""
echo "Quick curl commands:"
echo "  curl ${ENDPOINT}/v1/models"
echo "  curl -X POST ${ENDPOINT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"Qwen/Qwen3.6-27B\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50,\"chat_template_kwargs\":{\"enable_thinking\":false}}'"
echo ""
echo "Teardown:"
echo "  kubectl delete deployment qwen3-6-27b-vllm -n ${AIM_NAMESPACE}"
echo "  kubectl delete service qwen3-6-27b-vllm -n ${AIM_NAMESPACE}"
echo "  kubectl delete aimmodel qwen3-6-27b-vllm -n ${AIM_NAMESPACE}"
echo "  kubectl delete aimservice ${SERVICE_NAME} -n ${AIM_NAMESPACE}  # deletes PVC too"
echo "  kubectl delete aimclusterprofile ${PROFILE_NAME}"
echo "  kubectl delete aimclustermodel ${MODEL_NAME}"
echo ""
echo "Docs: docs/GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md"

disk_report "10-qwen3-6-27b-end"
