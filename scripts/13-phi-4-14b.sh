#!/usr/bin/env bash
# Deploy microsoft/phi-4 (14B fp16) on gfx1151 via AIM Engine managed AIMService.
#
# Prerequisites:
#   - DiffusionGemma paused (this script calls ensure-diffusiongemma-paused.sh)
#   - AIM Engine operator running
#   - scripts/03b-gfx1151-aim-labels.sh applied
#   - >= 45 GiB free disk (weights ~28 GiB fp16 + PVC overhead)
#
# Usage:
#   bash scripts/13-phi-4-14b.sh
#   CATALOG_ONLY=1 bash scripts/13-phi-4-14b.sh
#
# Post-Workbench Deploy:
#   bash scripts/ensure-phi-4-14b-profile-mount.sh demo
#   bash scripts/fix-aim-httproute-gateway.sh demo
#   bash scripts/ensure-phi-4-14b-chattable.sh
#
# See: docs/PHI4_14B_AIM_BLOOM_POST_INSTALL.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
AIM_NAMESPACE="${AIM_NAMESPACE:-demo}"
PROFILE_NAME="phi-4-14b-r9700-gfx1151-latency"
SERVICE_NAME="phi-4-14b"
MODEL_NAME="microsoft-phi-4-14b"
MANIFEST_DIR="$EAI_ROOT/manifests/aim/phi-4-14b"
NODE_IP="$(my_ip)"
LOCAL_REGISTRY="${LOCAL_REGISTRY:-$(registry_host)}"
export REGISTRY_HOST="${LOCAL_REGISTRY}"
AIM_IMAGE="${AIM_IMAGE:-${LOCAL_REGISTRY}/aim-gfx1151-phi-4-14b:0.11-therock}"
CATALOG_ONLY="${CATALOG_ONLY:-0}"

PROFILE_READY_TIMEOUT=120
DOWNLOAD_TIMEOUT=3600
POD_READY_TIMEOUT=1800

echo "=== 13-phi-4-14b (namespace=${AIM_NAMESPACE}) ==="

echo ""
echo "--- Step -2: Pause DiffusionGemma (free GPU + memory) ---"
bash "$SCRIPT_DIR/ensure-diffusiongemma-paused.sh" demo default || true
bash "$SCRIPT_DIR/pause-aim-inference.sh" demo || true
PAUSE_INFERENCE_EXCLUDE=phi-4 bash "$SCRIPT_DIR/pause-aim-inference.sh" default || true

echo ""
echo "--- Step -1: Stack startup hardening ---"
bash "$SCRIPT_DIR/ensure-stack-startup.sh" || true

EAI_MIN_FREE_GB=45 check_disk_before_step "13-phi-4-14b"
disk_report "13-phi-4-14b-start"

echo ""
echo "--- Step 0: Custom AIM image (${AIM_IMAGE}) ---"
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

if curl -sf "http://${LOCAL_REGISTRY}/v2/aim-gfx1151-phi-4-14b/tags/list" 2>/dev/null \
  | python3 -c "import sys,json; t=json.load(sys.stdin).get('tags',[]); sys.exit(0 if '0.11-therock' in t else 1)" 2>/dev/null; then
  echo "Image already in local registry — skipping build."
else
  echo "Building ${AIM_IMAGE} ..."
  docker build -t "${AIM_IMAGE}" "${EAI_ROOT}/images/aim-gfx1151-phi-4-14b/"
  docker push "${AIM_IMAGE}"
fi

echo ""
echo "--- Step 1: R9700 accelerator label ---"
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
if ! kubectl get node "${NODE}" --show-labels 2>/dev/null | grep -q 'aim-accelerator.R9700'; then
  bash "$SCRIPT_DIR/03b-gfx1151-aim-labels.sh"
fi

echo ""
echo "--- Step 2: AIMClusterModel ---"
envsubst '${REGISTRY_HOST}' < "${MANIFEST_DIR}/aim-clustermodel.yaml" | kubectl apply -f -

echo ""
echo "--- Step 3: AIMClusterProfile ---"
envsubst '${REGISTRY_HOST}' < "${MANIFEST_DIR}/aim-clusterprofile.yaml" | kubectl apply -f -

ELAPSED=0
while [[ $ELAPSED -lt $PROFILE_READY_TIMEOUT ]]; do
  PSTATUS=$(kubectl get aimclusterprofile "${PROFILE_NAME}" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  echo "  profile status: ${PSTATUS:-pending} (${ELAPSED}s)"
  [[ "$PSTATUS" == "Ready" ]] && break
  [[ "$PSTATUS" == "NotAvailable" ]] && {
    echo "ERROR: Profile NotAvailable — run: bash scripts/03b-gfx1151-aim-labels.sh"
    exit 1
  }
  sleep 10; ELAPSED=$((ELAPSED + 10))
done

echo ""
echo "--- Step 3b: AIMClusterServiceTemplate + profile ConfigMap ---"
kubectl apply -f "${MANIFEST_DIR}/aim-clusterservicetemplate.yaml"
kubectl apply -f "${MANIFEST_DIR}/phi-4-14b-r9700-gfx1151-latency-profile-configmap.yaml"
for _ in $(seq 1 30); do
  TSTATUS=$(kubectl get aimclusterservicetemplate "${PROFILE_NAME}" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  echo "  template status: ${TSTATUS:-pending}"
  [[ "$TSTATUS" == "Ready" ]] && break
  sleep 5
done

echo ""
echo "--- Step 3c: AIMRuntimeConfig/demo ---"
kubectl apply -f "${MANIFEST_DIR}/aim-runtimeconfig-demo.yaml"

if [[ "${CATALOG_ONLY}" == "1" ]]; then
  echo ""
  echo "CATALOG_ONLY=1: catalog CRs applied."
  echo "  Deploy from AI Workbench: /demo/models/aim-catalog"
  echo "  Before testing: bash scripts/ensure-diffusiongemma-paused.sh"
  disk_report "13-phi-4-14b-catalog-end"
  exit 0
fi

echo ""
echo "--- Step 4: AIMService ---"
kubectl apply -f "${MANIFEST_DIR}/aim-service.yaml"

echo ""
echo "--- Step 5: Waiting for weights download (up to ${DOWNLOAD_TIMEOUT}s) ---"
ELAPSED=0
PVC_NAME=""
while [[ $ELAPSED -lt $DOWNLOAD_TIMEOUT ]]; do
  PVC_NAME=$(kubectl get pvc -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -iE 'phi-4|phi4|microsoft.*phi' | awk '{print $1}' | head -1 || true)
  ART_NAME=$(kubectl get aimartifact -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
    | grep -iE 'phi-4|phi4|microsoft' | head -1 || true)
  if [[ -n "$ART_NAME" ]]; then
    ART_STATUS=$(kubectl get "$ART_NAME" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    echo "  artifact: ${ART_NAME##*/} status=${ART_STATUS:-unknown} pvc=${PVC_NAME:-none} (${ELAPSED}s)"
    case "$ART_STATUS" in
      Succeeded|Ready) break ;;
      Failed)
        echo "ERROR: AIMArtifact download failed."
        exit 1 ;;
    esac
  else
    echo "  searching for PVC/artifact (${ELAPSED}s)"
  fi
  sleep 30; ELAPSED=$((ELAPSED + 30))
done

echo ""
echo "--- Step 6: Post-deploy fixes ---"
bash "$SCRIPT_DIR/ensure-phi-4-14b-profile-mount.sh" "${AIM_NAMESPACE}"
bash "$SCRIPT_DIR/fix-aim-httproute-gateway.sh" "${AIM_NAMESPACE}" || true
bash "$SCRIPT_DIR/ensure-phi-4-14b-chattable.sh" || true

echo ""
echo "--- Step 7: Wait for predictor Ready (up to ${POD_READY_TIMEOUT}s) ---"
ISVC_NAME=""
ELAPSED=0
while [[ $ELAPSED -lt 120 ]]; do
  ISVC_NAME=$(kubectl get inferenceservice -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -iE 'phi-4|phi4|wb-aim' | awk '{print $1}' | head -1 || true)
  [[ -n "$ISVC_NAME" ]] && break
  sleep 10; ELAPSED=$((ELAPSED + 10))
done

if [[ -n "$ISVC_NAME" ]]; then
  ELAPSED=0
  while [[ $ELAPSED -lt $POD_READY_TIMEOUT ]]; do
    IS_STATUS=$(kubectl get inferenceservice "${ISVC_NAME}" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="PredictorReady")].status}' 2>/dev/null || echo "")
    echo "  PredictorReady=${IS_STATUS:-?} (${ELAPSED}s)"
    [[ "$IS_STATUS" == "True" ]] && break
    sleep 30; ELAPSED=$((ELAPSED + 30))
  done
fi

echo ""
echo "=== E2E Smoke Tests (in-cluster) ==="
POD=$(kubectl get pods -A -l "aim.eai.amd.com/model=${MODEL_NAME},component=predictor" \
  -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null | awk '{print $1}')
POD_NS=$(kubectl get pods -A -l "aim.eai.amd.com/model=${MODEL_NAME},component=predictor" \
  -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.namespace}' 2>/dev/null | awk '{print $1}')

if [[ -n "$POD" ]]; then
  echo "--- Test 1: GET /v1/models ---"
  kubectl exec -n "${POD_NS}" "$POD" -- curl -sf http://127.0.0.1:8000/v1/models | head -c 300 || true

  echo ""
  echo "--- Test 2: POST /v1/chat/completions ---"
  kubectl exec -n "${POD_NS}" "$POD" -- curl -sf --max-time 120 \
    -X POST http://127.0.0.1:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"microsoft/phi-4","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":10,"temperature":0}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('Response:', d['choices'][0]['message']['content'])" \
    2>/dev/null || echo "WARN: chat smoke failed"

  echo ""
  echo "--- Test 3: Tool-calling schema ---"
  kubectl exec -n "${POD_NS}" "$POD" -- curl -sf --max-time 120 \
    -X POST http://127.0.0.1:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"microsoft/phi-4","messages":[{"role":"user","content":"What is 2+2?"}],"tools":[{"type":"function","function":{"name":"calc","description":"Calculator","parameters":{"type":"object","properties":{"expr":{"type":"string"}}}}}],"max_tokens":30,"temperature":0}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('finish_reason:', d['choices'][0]['finish_reason'])" \
    2>/dev/null || echo "WARN: tool-calling check skipped"
else
  echo "WARN: No Ready predictor pod for smoke tests."
fi

bash "$SCRIPT_DIR/ensure-phi-4-llm-bridge.sh" || true

echo ""
echo "=== Summary ==="
echo "Model:    microsoft/phi-4 (14B, fp16)"
echo "Image:    ${AIM_IMAGE}"
echo "Profile:  ${PROFILE_NAME}"
echo "Docs:     docs/PHI4_14B_AIM_BLOOM_POST_INSTALL.md"
echo ""
echo "E2E:  E2E_AIWB=1 E2E_PHI4=1 pytest tests/e2e/test_aiwb_ui.py -k phi4 -v"
echo "Teardown: kubectl delete aimservice ${SERVICE_NAME} -n ${AIM_NAMESPACE}"

docker builder prune -af 2>/dev/null || true
disk_report "13-phi-4-14b-end"
