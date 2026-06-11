#!/usr/bin/env bash
# Deploy Phi-4-mini-instruct (3.8B) on gfx1151 via AIM Engine + plain K8s Deployment.
#
# WHY NOT AIMService?
#   amdenterpriseai/aim-base:0.11 uses a PyTorch build that lacks compiled gfx1151
#   kernels — torch.randn(..., device='cuda') segfaults on Strix Halo. The AIMService
#   InferenceService pod therefore cannot run vLLM. See docs/GFX1151_GPT_OSS_AIM_PROFILE.md.
#
# ACTUAL APPROACH (3-layer hybrid):
#   Layer 1 — AIM catalog:
#     AIMClusterModel  microsoft-phi-4-mini-instruct  (catalog registration)
#     AIMClusterProfile phi4-mini-r9700-gfx1151-latency (runtime config)
#   Layer 2 — Weight download:
#     AIMService phi4-mini is applied first → AIMArtifact download job creates the
#     PVC with Phi-4-mini weights (~7.5 GiB from hf://microsoft/Phi-4-mini-instruct).
#     The InferenceService pod will fail (segfault), but the PVC persists.
#   Layer 3 — Inference:
#     Plain K8s Deployment using kyuz0/vllm-therock-gfx1151:stable (Fedora 43 +
#     TheRock nightly ROCm + PyTorch compiled for gfx1151). Mounts the weights PVC.
#     AIMModel phi4-mini-vllm registers it in AI Workbench via external-endpoint.
#
# Endpoint: http://192.168.32.13:30400/v1  (NodePort 30400 → phi4-mini-vllm:8000)
#
# Prerequisites:
#   - AIM Engine operator running (kubectl get crd aimservices.aim.eai.amd.com)
#   - scripts/03b-gfx1151-aim-labels.sh applied (R9700 accelerator label on node)
#   - ~12 GiB free disk space for weights PVC
#
# Usage:
#   bash scripts/09-phi4-mini-aim-profile.sh
#   AIM_NAMESPACE=default bash scripts/09-phi4-mini-aim-profile.sh
#
# See: docs/GFX1151_GPT_OSS_AIM_PROFILE.md  docs/call-flows/03b-gfx1151-aim-labels.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
AIM_NAMESPACE="${AIM_NAMESPACE:-default}"
PROFILE_NAME="phi4-mini-r9700-gfx1151-latency"
SERVICE_NAME="phi4-mini"
MODEL_NAME="microsoft-phi-4-mini-instruct"
MANIFEST_DIR="$EAI_ROOT/manifests/aim/phi4-mini"
NODE_PORT=30400
NODE_IP="$(hostname -I | awk '{print $1}')"

# Timeouts
PROFILE_READY_TIMEOUT=120   # seconds
DOWNLOAD_TIMEOUT=1800       # 30 min — ~7.5 GiB
POD_READY_TIMEOUT=900       # 15 min — large image pull + vLLM startup

echo "=== 09-phi4-mini-aim-profile (namespace=${AIM_NAMESPACE}) ==="

# --- Disk guard (need ~12 GiB: weights + PVC overhead) ---
EAI_MIN_FREE_GB=12 check_disk_before_step "09-phi4-mini"
disk_report "09-phi4-mini-start"

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
  # Search for the PVC created by AIMArtifact
  PVC_NAME=$(kubectl get pvc -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -i "phi.*4.*mini\|microsoft.*phi" | awk '{print $1}' | head -1 || true)
  ART_NAME=$(kubectl get aimartifact -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
    | grep -i "phi\|microsoft" | head -1 || true)

  if [[ -n "$ART_NAME" ]]; then
    ART_STATUS=$(kubectl get "$ART_NAME" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    echo "  artifact: ${ART_NAME##*/} status=${ART_STATUS:-unknown} pvc=${PVC_NAME:-none} (${ELAPSED}s)"
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
      echo "PVC is Bound. Checking for model files..."
      FILE_COUNT=$(kubectl run pvc-check-$$ --rm --restart=Never \
        --image=busybox:latest -n "${AIM_NAMESPACE}" \
        -q --timeout=30s \
        -- sh -c "ls /data/*.safetensors 2>/dev/null | wc -l" \
        -- --volumeMounts='[{"name":"w","mountPath":"/data"}]' \
        -- --volumes='[{"name":"w","persistentVolumeClaim":{"claimName":"'"$PVC_NAME"'"}}]' \
        2>/dev/null || echo "0")
      [[ "$FILE_COUNT" -gt 0 ]] && { echo "Weights found ($FILE_COUNT shards)."; break; }
    }
  else
    SVCSTATUS=$(kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    echo "  aimservice status=${SVCSTATUS:-pending}, searching for PVC (${ELAPSED}s)"
  fi
  sleep 15; ELAPSED=$((ELAPSED + 15))
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
# The InferenceService pod is crashing. Scale it down so it doesn't hold GPU resources.
ISVC_NAME=$(kubectl get inferenceservice -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
  | grep -i "phi4\|phi-4" | awk '{print $1}' | head -1 || true)
if [[ -n "$ISVC_NAME" ]]; then
  echo "Scaling down InferenceService ${ISVC_NAME} replicas to 0..."
  kubectl patch inferenceservice "${ISVC_NAME}" -n "${AIM_NAMESPACE}" \
    --type='json' -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0}]' \
    2>/dev/null || \
  kubectl scale deployment -n "${AIM_NAMESPACE}" \
    -l "serving.kserve.io/inferenceservice=${ISVC_NAME}" --replicas=0 2>/dev/null || true
fi

# --- Step 7: Update deployment manifest with correct PVC name and deploy ---
echo ""
echo "--- Step 7: Deploy phi4-mini-vllm (kyuz0/vllm-therock-gfx1151:stable) ---"

# Patch the deployment manifest with the discovered PVC name
DEPLOY_MANIFEST="${MANIFEST_DIR}/phi4-mini-deployment.yaml"
# Use sed for in-place PVC name substitution (the manifest has the canonical PVC name)
CANONICAL_PVC="hf---microsoft-phi-4-mini-instruct-2e07ce61bb-cache-89d7670f"
if [[ "$PVC_NAME" != "$CANONICAL_PVC" ]]; then
  echo "  Patching PVC name: ${CANONICAL_PVC} → ${PVC_NAME}"
  sed -i "s|claimName: ${CANONICAL_PVC}|claimName: ${PVC_NAME}|g" "$DEPLOY_MANIFEST"
fi

kubectl apply -f "$DEPLOY_MANIFEST"

echo "Waiting for phi4-mini-vllm pod to become Ready (up to ${POD_READY_TIMEOUT}s)..."
echo "(Image pull of kyuz0/vllm-therock-gfx1151:stable takes ~5-8 min on first run)"
ELAPSED=0
while [[ $ELAPSED -lt $POD_READY_TIMEOUT ]]; do
  POD_STATUS=$(kubectl get pods -n "${AIM_NAMESPACE}" -l app=phi4-mini-vllm \
    --no-headers 2>/dev/null | head -1 || true)
  READY=$(echo "$POD_STATUS" | awk '{print $2}')
  STATUS=$(echo "$POD_STATUS" | awk '{print $3}')
  echo "  pod: ${READY:-0/1} ${STATUS:-unknown} (${ELAPSED}s)"
  [[ "$READY" == "1/1" ]] && { echo "Pod is Ready!"; break; }
  case "$STATUS" in
    CrashLoopBackOff|Error|OOMKilled)
      POD_NAME=$(echo "$POD_STATUS" | awk '{print $1}')
      echo "ERROR: Pod crashed. Logs:"
      kubectl logs "$POD_NAME" -n "${AIM_NAMESPACE}" --tail=30 2>/dev/null || true
      exit 1
      ;;
  esac
  sleep 20; ELAPSED=$((ELAPSED + 20))
done

if [[ "$(kubectl get pods -n "${AIM_NAMESPACE}" -l app=phi4-mini-vllm \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)" != "true" ]]; then
  echo "WARNING: Pod not Ready after ${POD_READY_TIMEOUT}s. May still be starting."
  echo "  Monitor: kubectl logs -n ${AIM_NAMESPACE} -l app=phi4-mini-vllm -f"
fi

# --- Step 8: Register in AI Workbench via AIMModel ---
echo ""
echo "--- Step 8: AIMModel (AI Workbench registration) ---"
kubectl apply -f "${MANIFEST_DIR}/phi4-mini-aimmodel.yaml"
echo "AIMModel phi4-mini-vllm registered."

# --- Step 9: E2E smoke tests ---
echo ""
echo "=== E2E Smoke Tests (endpoint: http://${NODE_IP}:${NODE_PORT}/v1) ==="

ENDPOINT="http://${NODE_IP}:${NODE_PORT}"

echo ""
echo "--- Test 1: GET /v1/models ---"
curl -sf --max-time 30 "${ENDPOINT}/v1/models" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Models:', [m['id'] for m in d['data']])" \
  2>/dev/null \
  || curl -s --max-time 30 "${ENDPOINT}/v1/models" | head -200

echo ""
echo "--- Test 2: POST /v1/chat/completions ---"
curl -sf --max-time 60 -X POST "${ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"microsoft/Phi-4-mini-instruct","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":5,"temperature":0}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Response:', d['choices'][0]['message']['content'])" \
  2>/dev/null \
  || curl -s --max-time 60 -X POST "${ENDPOINT}/v1/chat/completions" \
     -H "Content-Type: application/json" \
     -d '{"model":"microsoft/Phi-4-mini-instruct","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":5,"temperature":0}'

echo ""
echo "=== Summary ==="
echo "Model:    microsoft/Phi-4-mini-instruct (3.8B, fp16)"
echo "Engine:   vLLM (kyuz0/vllm-therock-gfx1151:stable — TheRock nightly ROCm, gfx1151)"
echo "AIM:      AIMClusterModel + AIMClusterProfile (phi4-mini-r9700-gfx1151-latency)"
echo "Service:  phi4-mini-vllm (NodePort ${NODE_PORT})"
echo "AIMModel: phi4-mini-vllm (AI Workbench registration)"
echo ""
echo "Endpoint:  ${ENDPOINT}/v1"
echo ""
echo "Quick curl commands:"
echo "  curl ${ENDPOINT}/v1/models"
echo "  curl -X POST ${ENDPOINT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"microsoft/Phi-4-mini-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}'"
echo ""
echo "Teardown:"
echo "  kubectl delete deployment phi4-mini-vllm -n ${AIM_NAMESPACE}"
echo "  kubectl delete service phi4-mini-vllm -n ${AIM_NAMESPACE}"
echo "  kubectl delete aimmodel phi4-mini-vllm -n ${AIM_NAMESPACE}"
echo "  kubectl delete aimservice ${SERVICE_NAME} -n ${AIM_NAMESPACE}  # deletes PVC too"
echo "  kubectl delete aimclusterprofile ${PROFILE_NAME}"
echo "  kubectl delete aimclustermodel ${MODEL_NAME}"
echo ""
echo "Docs: docs/GFX1151_GPT_OSS_AIM_PROFILE.md"

disk_report "09-phi4-mini-end"
