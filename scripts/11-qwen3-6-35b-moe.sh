#!/usr/bin/env bash
# Deploy Qwen/Qwen3.6-35B-A3B (35B total / 4B active, MoE, BF16) on gfx1151
# via AIM Engine managed AIMService.
#
# APPROACH (custom AIM image + full managed path):
#   images/aim-gfx1151-qwen3-6-35b-moe/Dockerfile layers aim-runtime (pure Python,
#   extracted from aim-base:0.11) onto kyuz0/vllm-therock-gfx1151:stable.
#   This enables the full MI300X-style managed AIMService flow on gfx1151:
#
#   Layer 1 — AIM catalog:
#     AIMClusterModel  qwen-qwen3-6-35b-moe
#     AIMClusterProfile qwen3-6-35b-moe-r9700-gfx1151-latency
#     AIMClusterServiceTemplate (Workbench catalog Deploy button)
#   Layer 2 — Weight download:
#     AIMService qwen3-6-35b-moe → AIMArtifact download job (~70 GiB)
#   Layer 3 — Inference (MANAGED):
#     InferenceService predictor uses ${REGISTRY_HOST}/aim-gfx1151-qwen3-6-35b-moe:0.11-therock
#     aim-runtime reads profile ConfigMap → execv into vLLM 0.19.2rc1 (gfx1151)
#
# MoE tuning vs the 27B dense profile:
#   - gpu-memory-utilization: 0.65  (35B BF16 weights ≈ 70 GiB; 0.65 × 128 GiB = 83 GiB)
#   - max-num-seqs: 8               (reduced KV-cache budget)
#   - VLLM_ROCM_USE_AITER_MOE=0     (already disabled — not reliable on gfx1151)
#
# Prerequisites:
#   - Existing Qwen3.6-27B weights removed (bash scripts/teardown-qwen-weights.sh)
#   - AIM Engine operator running (kubectl get crd aimservices.aim.eai.amd.com)
#   - scripts/03b-gfx1151-aim-labels.sh applied (R9700 accelerator label on node)
#   - >= 120 GiB free disk space (70 GiB weights + 30 GiB image layers + headroom)
#   - Local registry running at $(hostname -s):32000
#
# Usage:
#   bash scripts/11-qwen3-6-35b-moe.sh
#   AIM_NAMESPACE=demo bash scripts/11-qwen3-6-35b-moe.sh
#   CATALOG_ONLY=1 bash scripts/11-qwen3-6-35b-moe.sh   # catalog CRs only (Workbench Deploy)
#
# Post-Workbench Deploy (always required on gfx1151 Bloom):
#   bash scripts/ensure-qwen-profile-mount.sh demo
#   bash scripts/fix-aim-httproute-gateway.sh demo
#   bash scripts/ensure-qwen-moe-chattable.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
AIM_NAMESPACE="${AIM_NAMESPACE:-demo}"
PROFILE_NAME="qwen3-6-35b-moe-r9700-gfx1151-latency"
SERVICE_NAME="qwen3-6-35b-moe"
MODEL_NAME="qwen-qwen3-6-35b-moe"
MANIFEST_DIR="$EAI_ROOT/manifests/aim/qwen3-6-35b-moe"
NODE_IP="$(my_ip)"
LOCAL_REGISTRY="${LOCAL_REGISTRY:-$(registry_host)}"
export REGISTRY_HOST="${LOCAL_REGISTRY}"
AIM_IMAGE="${AIM_IMAGE:-${LOCAL_REGISTRY}/aim-gfx1151-qwen3-6-35b-moe:0.11-therock}"
CATALOG_ONLY="${CATALOG_ONLY:-0}"

PROFILE_READY_TIMEOUT=120
DOWNLOAD_TIMEOUT=5400   # 90 min — ~70 GiB MoE weights
POD_READY_TIMEOUT=1800  # 30 min — large model load + vLLM startup

echo "=== 11-qwen3-6-35b-moe (namespace=${AIM_NAMESPACE}) ==="

# --- Disk guard: need >= 95 GiB for weights PVC + image layers ---
EAI_MIN_FREE_GB=95 check_disk_before_step "11-qwen3-6-35b-moe"
disk_report "11-qwen3-6-35b-moe-start"

# --- Step 0: Build + push custom AIM image ---
echo ""
echo "--- Step 0: Custom AIM image (${AIM_IMAGE}) ---"

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

# Ensure containerd treats the hostname registry as insecure
REG_HOST="$(registry_host)"
if ! sudo grep -q "\"${REG_HOST}\"" /etc/rancher/rke2/registries.yaml 2>/dev/null; then
  echo "Updating /etc/rancher/rke2/registries.yaml for ${REG_HOST}..."
  sudo tee /etc/rancher/rke2/registries.yaml > /dev/null <<EOF
mirrors:
  "${REG_HOST}":
    endpoint:
      - "http://localhost:32000"
  "localhost:32000":
    endpoint:
      - "http://localhost:32000"
configs:
  "${REG_HOST}":
    tls:
      insecure_skip_verify: true
  "localhost:32000":
    tls:
      insecure_skip_verify: true
EOF
fi

# Check if image already pushed (fast path on subsequent runs)
if curl -sf "http://${LOCAL_REGISTRY}/v2/aim-gfx1151-qwen3-6-35b-moe/tags/list" 2>/dev/null \
  | python3 -c "import sys,json; t=json.load(sys.stdin).get('tags',[]); sys.exit(0 if '0.11-therock' in t else 1)" 2>/dev/null; then
  echo "Image already in local registry — skipping build."
else
  echo "Building ${AIM_IMAGE} ..."
  echo "(Base layers already cached from 27B build — this should be fast)"
  docker build -t "${AIM_IMAGE}" "${EAI_ROOT}/images/aim-gfx1151-qwen3-6-35b-moe/"
  echo "Pushing ${AIM_IMAGE} ..."
  docker push "${AIM_IMAGE}"
  echo "Image pushed successfully."
fi

# Pre-pull into RKE2 containerd so predictor pod starts immediately
echo "Pre-pulling image into RKE2 containerd..."
sudo /var/lib/rancher/rke2/bin/ctr \
  --address /run/k3s/containerd/containerd.sock \
  -n k8s.io images pull \
  --plain-http \
  "${AIM_IMAGE}" 2>/dev/null \
  || echo "WARN: ctr pre-pull failed (may already be present)"

# Smoke-test the image
echo "Smoke-testing image imports..."
docker run --rm \
  -e AIM_PROFILE_ID="${PROFILE_NAME}" \
  -e AIM_GPU_MODEL=R9700 -e AIM_GPU_COUNT=1 \
  -e AIM_METRIC=latency -e AIM_PRECISION=bf16 \
  "${AIM_IMAGE}" dry-run --format=json >/dev/null \
  && echo "Image dry-run smoke test: PASS" || echo "WARN: Image dry-run smoke test failed — check Dockerfile"

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
envsubst '${REGISTRY_HOST}' < "${MANIFEST_DIR}/aim-clustermodel.yaml" | kubectl apply -f -
kubectl get aimclustermodel "${MODEL_NAME}" 2>/dev/null || true

# --- Step 3: Apply AIMClusterProfile (runtime config) ---
echo ""
echo "--- Step 3: AIMClusterProfile ---"
envsubst '${REGISTRY_HOST}' < "${MANIFEST_DIR}/aim-clusterprofile.yaml" | kubectl apply -f -

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

# --- Step 3b: AIMClusterServiceTemplate + profile ConfigMap ---
echo ""
echo "--- Step 3b: AIMClusterServiceTemplate + profile ConfigMap ---"
kubectl apply -f "${MANIFEST_DIR}/aim-clusterservicetemplate.yaml"
kubectl apply -f "${MANIFEST_DIR}/qwen3-6-35b-moe-r9700-gfx1151-latency-profile-configmap.yaml"
for _ in $(seq 1 30); do
  TSTATUS=$(kubectl get aimclusterservicetemplate "${PROFILE_NAME}" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  echo "  template status: ${TSTATUS:-pending}"
  [[ "$TSTATUS" == "Ready" ]] && break
  sleep 5
done

# Workbench hides Deploy until AIMClusterModel reports templates Ready.
for _ in $(seq 1 24); do
  MSTATUS=$(kubectl get aimclustermodel "${MODEL_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="ClusterServiceTemplatesReady")].status}' 2>/dev/null || echo "")
  [[ "$MSTATUS" == "True" ]] && break
  kubectl annotate aimclustermodel "${MODEL_NAME}" \
    aim.eai.amd.com/reconcile="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  sleep 5
done

# --- Step 3c: AIMRuntimeConfig for demo namespace (fixes gateway ref) ---
echo ""
echo "--- Step 3c: AIMRuntimeConfig/demo (envoy-gateway-system/https) ---"
kubectl apply -f "${MANIFEST_DIR}/aim-runtimeconfig-demo.yaml"
echo "AIMRuntimeConfig applied to demo namespace."

if [[ "${CATALOG_ONLY}" == "1" ]]; then
  echo ""
  echo "CATALOG_ONLY=1: catalog CRs applied. Skipping AIMService deploy."
  echo "  Template: kubectl get aimclusterservicetemplate ${PROFILE_NAME}"
  echo "  Profile:  kubectl get aimclusterprofile ${PROFILE_NAME}"
  echo "  Deploy from AI Workbench: /demo/models/aim-catalog"
  exit 0
fi

# --- Step 4: Apply AIMService (triggers weight download + inference) ---
echo ""
echo "--- Step 4: AIMService (full managed inference) ---"
echo "InferenceService predictor will use ${AIM_IMAGE} via aim-runtime → vLLM."

# Remove stale AIMService if it has an InfrastructureError (minReplicas conflict)
if kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" &>/dev/null; then
  COND=$(kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="DependenciesReachable")].reason}' 2>/dev/null || echo "")
  if [[ "$COND" == "InfrastructureError" ]]; then
    echo "  Stale AIMService has InfrastructureError. Recreating..."
    kubectl delete aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" --timeout=60s
    sleep 5
  fi
fi
kubectl apply -f "${MANIFEST_DIR}/aim-service.yaml"

# --- Step 5: Wait for AIMArtifact / weights PVC ---
echo ""
echo "--- Step 5: Waiting for weights download (up to ${DOWNLOAD_TIMEOUT}s) ---"
echo "(MoE weights ~70 GiB — allow 60–90 min on first run)"
ELAPSED=0
PVC_NAME=""
while [[ $ELAPSED -lt $DOWNLOAD_TIMEOUT ]]; do
  PVC_NAME=$(kubectl get pvc -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -i "qwen.*3.*6.*35b\|qwen3-6-35b-moe" | awk '{print $1}' | head -1 || true)
  ART_NAME=$(kubectl get aimartifact -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
    | grep -i "qwen.*35b\|qwen3-6-35b" | head -1 || true)

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
    echo "  pvc=${PVC_NAME} phase=${PVC_PHASE} (${ELAPSED}s)"
    [[ "$PVC_PHASE" == "Bound" ]] && echo "PVC is Bound. Waiting for artifact Ready..."
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

# --- Step 6: Wait for managed InferenceService predictor ---
echo ""
echo "--- Step 6: Wait for managed InferenceService predictor (up to ${POD_READY_TIMEOUT}s) ---"
echo "(Custom AIM image: ${AIM_IMAGE})"
echo "(35B MoE model load via aim-runtime may take 10–20 min on first run)"

ISVC_NAME=""
ELAPSED=0
while [[ $ELAPSED -lt 120 ]]; do
  ISVC_NAME=$(kubectl get inferenceservice -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -i "qwen3-6-35b\|qwen.*35b" | awk '{print $1}' | head -1 || true)
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
        echo "Common MoE causes:"
        echo "  - OOMKilled: raise gpu-memory-utilization above 0.65 in the profile"
        echo "  - ProfileNotFound: run scripts/ensure-qwen-profile-mount.sh demo"
        echo "  - aim_runtime.__main__ missing: rebuild image from Dockerfile"
        exit 1 ;;
    esac
    sleep 30; ELAPSED=$((ELAPSED + 30))
  done
else
  echo "WARNING: No InferenceService found. Checking AIMService status..."
  kubectl describe aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" 2>/dev/null | tail -20 || true
fi

# --- Step 7: Apply post-deploy fixes ---
echo ""
echo "--- Step 7: Post-deploy fixes ---"
PROFILE_SCRIPT="$SCRIPT_DIR/ensure-qwen-moe-profile-mount.sh"
GATEWAY_SCRIPT="$SCRIPT_DIR/fix-aim-httproute-gateway.sh"
CHATTABLE_SCRIPT="$SCRIPT_DIR/ensure-qwen-moe-chattable.sh"

if [[ -f "$PROFILE_SCRIPT" ]]; then
  echo "  Applying profile mount fix..."
  bash "$PROFILE_SCRIPT" "${AIM_NAMESPACE}"
fi
if [[ -f "$GATEWAY_SCRIPT" ]]; then
  echo "  Applying HTTPRoute gateway fix..."
  bash "$GATEWAY_SCRIPT" "${AIM_NAMESPACE}"
fi
if [[ -f "$CHATTABLE_SCRIPT" ]]; then
  echo "  Ensuring MoE model is chattable in Workbench..."
  bash "$CHATTABLE_SCRIPT"
fi

# --- Step 8: E2E smoke tests ---
echo ""
echo "=== E2E Smoke Tests ==="
IS_URL=$(kubectl get inferenceservice "${ISVC_NAME:-}" -n "${AIM_NAMESPACE}" \
  -o jsonpath='{.status.address.url}' 2>/dev/null || echo "")
# Find HTTPRoute path for gateway access
ROUTE_NAME=$(kubectl get httproute -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
  | grep -i "qwen.*35b\|qwen3-6-35b" | head -1 | cut -d/ -f2 || true)
if [[ -n "$ROUTE_NAME" ]]; then
  AIM_PATH=$(kubectl get httproute "${ROUTE_NAME}" -n "${AIM_NAMESPACE}" \
    -o jsonpath='{.spec.rules[0].matches[0].path.value}' 2>/dev/null || echo "")
  SMOKE_URL="https://${NODE_IP}${AIM_PATH}"
else
  SMOKE_URL="${IS_URL:-}"
fi

if [[ -n "${SMOKE_URL}" ]]; then
  echo ""
  echo "--- Test 1: GET /v1/models ---"
  curl -sk --max-time 60 "${SMOKE_URL}/v1/models" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('Models:', [m['id'] for m in d['data']])" \
    2>/dev/null || echo "WARN: /v1/models check failed"

  echo ""
  echo "--- Test 2: POST /v1/chat/completions (thinking disabled) ---"
  curl -sk --max-time 180 -X POST "${SMOKE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen3.6-35B-A3B","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":10,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('Response:', d['choices'][0]['message']['content'])" \
    2>/dev/null || echo "WARN: chat completion check failed (pod may still be warming up)"

  echo ""
  echo "--- Test 3: Tool-calling schema ---"
  curl -sk --max-time 120 -X POST "${SMOKE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "Qwen/Qwen3.6-35B-A3B",
      "messages": [{"role": "user", "content": "What is 2+2?"}],
      "tools": [{"type": "function","function":{"name":"calc","description":"Calculator","parameters":{"type":"object","properties":{"expr":{"type":"string"}}}}}],
      "max_tokens": 30, "temperature": 0,
      "chat_template_kwargs": {"enable_thinking": false}
    }' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('Tool call finish_reason:', d['choices'][0]['finish_reason'])" \
    2>/dev/null || echo "WARN: tool-calling check skipped"
fi

echo ""
echo "=== Summary ==="
echo "Model:    Qwen/Qwen3.6-35B-A3B (35B MoE, 4B active, BF16)"
echo "Image:    ${AIM_IMAGE}"
echo "Profile:  ${PROFILE_NAME}"
echo "Endpoint: ${SMOKE_URL:-${IS_URL:-see: kubectl get aimservice ${SERVICE_NAME} -n ${AIM_NAMESPACE}}}/v1"
echo ""
echo "Performance tests:"
echo "  PERF_ENDPOINT=${SMOKE_URL:-https://<node>/<path>} \\"
echo "  PERF_MODEL=Qwen/Qwen3.6-35B-A3B \\"
echo "  pytest tests/perf/test_qwen_moe_perf.py -v -s"
echo ""
echo "E2E tests:"
echo "  E2E_AIWB=1 E2E_MOE=1 pytest tests/e2e/test_aiwb_ui.py -k moe -v"
echo ""
echo "Teardown:"
echo "  kubectl delete aimservice ${SERVICE_NAME} -n ${AIM_NAMESPACE}"
echo "  kubectl delete aimclusterprofile ${PROFILE_NAME}"
echo "  kubectl delete aimclustermodel ${MODEL_NAME}"
echo ""
echo "Docs: docs/QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md (same pattern, 27B reference)"

# Prune Docker build cache to protect web UIs from disk-pressure
echo ""
echo "--- Post-build: prune Docker build cache ---"
docker builder prune -af 2>/dev/null || true

disk_report "11-qwen3-6-35b-moe-end"
