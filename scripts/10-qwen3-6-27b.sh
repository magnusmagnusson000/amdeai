#!/usr/bin/env bash
# Deploy Qwen/Qwen3.6-27B (27B BF16) on gfx1151 via AIM Engine managed AIMService.
#
# APPROACH (custom AIM image + full managed path):
#   images/aim-gfx1151-qwen3-6-27b/Dockerfile layers aim-runtime (pure Python,
#   extracted from aim-base:0.11) onto kyuz0/vllm-therock-gfx1151:stable.
#   This enables the full MI300X-style managed AIMService flow on gfx1151:
#
#   Layer 1 — AIM catalog:
#     AIMClusterModel  qwen-qwen3-6-27b
#     AIMClusterProfile qwen3-6-27b-r9700-gfx1151-latency
#     AIMClusterServiceTemplate (Workbench catalog Deploy button)
#   Layer 2 — Weight download:
#     AIMService qwen3-6-27b → AIMArtifact download job (~55.6 GiB)
#   Layer 3 — Inference (MANAGED — no separate Deployment needed):
#     InferenceService predictor uses 192.168.32.13:32000/aim-gfx1151-qwen3-6-27b:0.11-therock
#     aim-runtime reads profile ConfigMap → execv into vLLM 0.19.2rc1 (gfx1151)
#
# HYBRID FALLBACK:
#   If SKIP_MANAGED_BUILD=1, falls back to the original hybrid approach:
#   plain K8s Deployment (qwen3-6-27b-vllm) + AIMModel external endpoint.
#
# Prerequisites:
#   - AIM Engine operator running (kubectl get crd aimservices.aim.eai.amd.com)
#   - scripts/03b-gfx1151-aim-labels.sh applied (R9700 accelerator label on node)
#   - ~60 GiB free disk space for weights PVC
#   - Local registry running at 192.168.32.13:32000 (auto-deployed by this script)
#
# Usage:
#   bash scripts/10-qwen3-6-27b.sh
#   AIM_NAMESPACE=default bash scripts/10-qwen3-6-27b.sh
#   SKIP_MANAGED_BUILD=1 bash scripts/10-qwen3-6-27b.sh  # hybrid fallback
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
LOCAL_REGISTRY="${LOCAL_REGISTRY:-192.168.32.13:32000}"
AIM_IMAGE="${AIM_IMAGE:-${LOCAL_REGISTRY}/aim-gfx1151-qwen3-6-27b:0.11-therock}"
SKIP_MANAGED_BUILD="${SKIP_MANAGED_BUILD:-0}"

PROFILE_READY_TIMEOUT=120
DOWNLOAD_TIMEOUT=3600       # 60 min — ~55.6 GiB
POD_READY_TIMEOUT=1800      # 30 min — large model load + vLLM startup

echo "=== 10-qwen3-6-27b (namespace=${AIM_NAMESPACE}) ==="

# --- Disk guard (need ~60 GiB for weights PVC) ---
EAI_MIN_FREE_GB=60 check_disk_before_step "10-qwen3-6-27b"
disk_report "10-qwen3-6-27b-start"

# --- Step 0: Build + push custom AIM image (skip if already present or SKIP_MANAGED_BUILD=1) ---
echo ""
echo "--- Step 0: Custom AIM image (${AIM_IMAGE}) ---"
if [[ "${SKIP_MANAGED_BUILD}" == "1" ]]; then
  echo "SKIP_MANAGED_BUILD=1: skipping image build; using hybrid fallback."
else
  # Ensure local registry is running
  if ! kubectl get svc registry -n kube-system &>/dev/null; then
    echo "Deploying local registry at NodePort 32000..."
    kubectl apply -f - <<'REGEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: registry}
  template:
    metadata:
      labels: {app: registry}
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: data
          mountPath: /var/lib/registry
      volumes:
      - name: data
        hostPath:
          path: /var/lib/rancher/registry-data
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: kube-system
spec:
  type: NodePort
  selector: {app: registry}
  ports:
  - port: 5000
    targetPort: 5000
    nodePort: 32000
REGEOF
    kubectl rollout status deployment/registry -n kube-system --timeout=120s
  fi

  # Check if image already pushed (faster subsequent runs)
  if curl -sf "http://${LOCAL_REGISTRY}/v2/aim-gfx1151-qwen3-6-27b/tags/list" 2>/dev/null \
    | python3 -c "import sys,json; t=json.load(sys.stdin).get('tags',[]); sys.exit(0 if '0.11-therock' in t else 1)" 2>/dev/null; then
    echo "Image already in local registry — skipping build."
  else
    echo "Building ${AIM_IMAGE} ..."
    docker build -t "${AIM_IMAGE}" "${EAI_ROOT}/images/aim-gfx1151-qwen3-6-27b/"
    echo "Pushing ${AIM_IMAGE} ..."
    docker push "${AIM_IMAGE}"
    echo "Image pushed successfully."
  fi
fi

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

# --- Step 3c: AIMRuntimeConfig for demo namespace (fixes gateway ref) ---
echo ""
echo "--- Step 3c: AIMRuntimeConfig/demo (envoy-gateway-system/https) ---"
kubectl apply -f "${MANIFEST_DIR}/aim-runtimeconfig-demo.yaml"
echo "AIMRuntimeConfig applied to demo namespace."

# --- Step 4: Apply AIMService to trigger weight download and inference ---
echo ""
if [[ "${SKIP_MANAGED_BUILD}" == "1" ]]; then
  echo "--- Step 4: AIMService (weight download — hybrid fallback) ---"
  echo "NOTE: InferenceService pod will crash (aim-base:0.11 lacks gfx1151 kernels)."
  echo "      Weights PVC will be reused by the plain Deployment in Step 7."
else
  echo "--- Step 4: AIMService (full managed inference) ---"
  echo "InferenceService predictor will use ${AIM_IMAGE} via aim-runtime → vLLM."
  # If a stale AIMService exists with a minReplicas conflict, delete and recreate
  if kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" &>/dev/null; then
    SVCSTATUS=$(kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    COND=$(kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="DependenciesReachable")].reason}' 2>/dev/null || echo "")
    if [[ "$COND" == "InfrastructureError" ]]; then
      echo "  Stale AIMService has InfrastructureError (minReplicas conflict). Recreating..."
      kubectl delete aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" --timeout=60s
      sleep 5
    fi
  fi
fi
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

# --- Step 6: Wait for InferenceService predictor ---
echo ""
if [[ "${SKIP_MANAGED_BUILD}" == "1" ]]; then
  # ---- HYBRID FALLBACK PATH ----
  echo "--- Step 6: Pause AIMService pod (hybrid fallback: weights PVC only) ---"
  ISVC_NAME=$(kubectl get inferenceservice -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -i "qwen3\|qwen-3" | awk '{print $1}' | head -1 || true)
  if [[ -n "$ISVC_NAME" ]]; then
    echo "Scaling down InferenceService ${ISVC_NAME} (aim-base will crash on gfx1151)..."
    kubectl patch inferenceservice "${ISVC_NAME}" -n "${AIM_NAMESPACE}" \
      --type='json' -p='[{"op":"replace","path":"/spec/predictor/minReplicas","value":0}]' \
      2>/dev/null || \
    kubectl scale deployment -n "${AIM_NAMESPACE}" \
      -l "serving.kserve.io/inferenceservice=${ISVC_NAME}" --replicas=0 2>/dev/null || true
  fi

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
        exit 1 ;;
    esac
    sleep 30; ELAPSED=$((ELAPSED + 30))
  done

  echo ""
  echo "--- Step 8: AIMModel (AI Workbench registration — hybrid external endpoint) ---"
  AIMMODEL_MANIFEST="${MANIFEST_DIR}/qwen3-6-27b-aimmodel.yaml"
  sed -i "s|aim.eai.amd.com/external-endpoint: http://[0-9.]*:${NODE_PORT}|aim.eai.amd.com/external-endpoint: http://${NODE_IP}:${NODE_PORT}|g" \
    "$AIMMODEL_MANIFEST"
  kubectl apply -f "$AIMMODEL_MANIFEST"

  ENDPOINT="http://${NODE_IP}:${NODE_PORT}"
  SERVING_MODE="Hybrid (plain Deployment + AIMModel external endpoint)"

else
  # ---- MANAGED PATH ----
  echo "--- Step 6: Wait for managed InferenceService predictor (up to ${POD_READY_TIMEOUT}s) ---"
  echo "(Custom AIM image: ${AIM_IMAGE})"
  echo "(27B model load via aim-runtime may take 10–20 min on first run)"
  ISVC_NAME=""
  ELAPSED=0
  while [[ $ELAPSED -lt 120 ]]; do
    ISVC_NAME=$(kubectl get inferenceservice -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
      | grep -i "qwen3\|qwen-3" | awk '{print $1}' | head -1 || true)
    [[ -n "$ISVC_NAME" ]] && break
    echo "  Waiting for InferenceService to be created... (${ELAPSED}s)"
    sleep 10; ELAPSED=$((ELAPSED + 10))
  done

  if [[ -n "$ISVC_NAME" ]]; then
    echo "  InferenceService: ${ISVC_NAME}"
    ELAPSED=0
    while [[ $ELAPSED -lt $POD_READY_TIMEOUT ]]; do
      POD_STATUS=$(kubectl get pods -n "${AIM_NAMESPACE}" \
        -l "serving.kserve.io/inferenceservice=${ISVC_NAME}" \
        --no-headers 2>/dev/null | head -1 || true)
      READY=$(echo "$POD_STATUS" | awk '{print $2}')
      STATUS=$(echo "$POD_STATUS" | awk '{print $3}')
      IS_STATUS=$(kubectl get inferenceservice "${ISVC_NAME}" -n "${AIM_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="PredictorReady")].status}' 2>/dev/null || echo "")
      echo "  predictor pod: ${READY:-0/1} ${STATUS:-pending} | IS PredictorReady=${IS_STATUS:-?} (${ELAPSED}s)"
      [[ "$IS_STATUS" == "True" ]] && { echo "Predictor is Ready!"; break; }
      case "$STATUS" in
        CrashLoopBackOff|Error|OOMKilled)
          POD_NAME=$(echo "$POD_STATUS" | awk '{print $1}')
          echo "ERROR: Predictor pod crashed. Logs:"
          kubectl logs "$POD_NAME" -n "${AIM_NAMESPACE}" --tail=80 2>/dev/null || true
          echo ""
          echo "If aim-runtime module not found, check image PYTHONPATH and entrypoint."
          echo "Fallback: SKIP_MANAGED_BUILD=1 bash scripts/10-qwen3-6-27b.sh"
          exit 1 ;;
      esac
      sleep 30; ELAPSED=$((ELAPSED + 30))
    done
  else
    echo "WARNING: No InferenceService found. Checking AIMService status..."
    kubectl describe aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" 2>/dev/null | tail -20 || true
  fi

  # Get in-cluster endpoint URL
  IS_URL=$(kubectl get inferenceservice "${ISVC_NAME}" -n "${AIM_NAMESPACE}" \
    -o jsonpath='{.status.address.url}' 2>/dev/null || echo "")
  ENDPOINT="${IS_URL:-http://${NODE_IP}:${NODE_PORT}}"
  SERVING_MODE="Managed AIMService (aim-runtime → vLLM 0.19.2rc1 on gfx1151)"
fi

# --- Step 7 (managed): Wait for HTTPRoute ---
echo ""
echo "--- Step 7: HTTPRoute status ---"
HTTPROUTE_STATUS=$(kubectl get httproute -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
  | grep -i "qwen" | head -1 || true)
echo "  ${HTTPROUTE_STATUS:-No HTTPRoute found yet}"

# --- Step 8: E2E smoke tests ---
echo ""
echo "=== E2E Smoke Tests ==="
echo "  Serving mode: ${SERVING_MODE}"
# For managed path, prefer the external NodePort for smoke tests
SMOKE_ENDPOINT="http://${NODE_IP}:${NODE_PORT}"
# Also check the in-cluster IS URL if available
if [[ -n "${IS_URL:-}" ]]; then
  SMOKE_ENDPOINT_ALT="${IS_URL}"
fi

echo ""
echo "--- Test 1: GET /health (NodePort ${NODE_PORT}) ---"
curl -sf --max-time 30 "${SMOKE_ENDPOINT}/health" && echo " OK" \
  || echo "WARN: health check failed (pod may still be loading)"

echo ""
echo "--- Test 2: GET /v1/models ---"
curl -sf --max-time 60 "${SMOKE_ENDPOINT}/v1/models" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Models:', [m['id'] for m in d['data']])" \
  2>/dev/null \
  || curl -s --max-time 60 "${SMOKE_ENDPOINT}/v1/models" | head -200

echo ""
echo "--- Test 3: POST /v1/chat/completions (thinking disabled) ---"
curl -sf --max-time 120 -X POST "${SMOKE_ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3.6-27B","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":10,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Response:', d['choices'][0]['message']['content'])" \
  2>/dev/null \
  || curl -s --max-time 120 -X POST "${SMOKE_ENDPOINT}/v1/chat/completions" \
     -H "Content-Type: application/json" \
     -d '{"model":"Qwen/Qwen3.6-27B","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":10,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}'

echo ""
echo "=== Summary ==="
echo "Model:    Qwen/Qwen3.6-27B (27B, bf16)"
echo "Image:    ${AIM_IMAGE}"
echo "Mode:     ${SERVING_MODE}"
echo "Profile:  ${PROFILE_NAME}"
echo ""
echo "Endpoint:  ${SMOKE_ENDPOINT}/v1"
echo ""
echo "Quick curl commands:"
echo "  curl ${SMOKE_ENDPOINT}/v1/models"
echo "  curl -X POST ${SMOKE_ENDPOINT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"Qwen/Qwen3.6-27B\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50,\"chat_template_kwargs\":{\"enable_thinking\":false}}'"
echo ""
echo "Teardown (managed):"
echo "  kubectl delete aimservice ${SERVICE_NAME} -n ${AIM_NAMESPACE}"
echo "  kubectl delete aimclusterprofile ${PROFILE_NAME}"
echo "  kubectl delete aimclustermodel ${MODEL_NAME}"
echo ""
echo "Docs: docs/GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md"

disk_report "10-qwen3-6-27b-end"
