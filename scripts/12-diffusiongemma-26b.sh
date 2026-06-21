#!/usr/bin/env bash
# Deploy google/diffusiongemma-26B-A4B-it on gfx1151 via AIM Engine managed AIMService.
#
# DiffusionGemma is a discrete diffusion LLM (26B total / 4B active MoE) on Gemma 4.
# vLLM serves it with diffusion-specific flags (chunked prefill, diffusion-config).
#
# Prerequisites:
#   - HF_TOKEN set (Gemma gated model) — configured at AIWB install via 06b-airm-workbench.sh
#   - AIM Engine operator running
#   - scripts/03b-gfx1151-aim-labels.sh applied
#   - >= 95 GiB free disk (weights ~50 GiB + image layers)
#   - Pause other AIM inference to free GPU: bash scripts/pause-aim-inference.sh demo
#
# Usage:
#   bash scripts/12-diffusiongemma-26b.sh
#   CATALOG_ONLY=1 bash scripts/12-diffusiongemma-26b.sh
#
# Post-Workbench Deploy:
#   bash scripts/ensure-diffusiongemma-profile-mount.sh demo
#   bash scripts/fix-aim-httproute-gateway.sh demo
#   bash scripts/ensure-diffusiongemma-chattable.sh
#
# See: docs/DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
AIM_NAMESPACE="${AIM_NAMESPACE:-demo}"
PROFILE_NAME="diffusiongemma-26b-r9700-gfx1151-latency"
SERVICE_NAME="diffusiongemma-26b"
MODEL_NAME="google-diffusiongemma-26b"
MANIFEST_DIR="$EAI_ROOT/manifests/aim/diffusiongemma-26b"
NODE_IP="$(my_ip)"
LOCAL_REGISTRY="${LOCAL_REGISTRY:-$(registry_host)}"
export REGISTRY_HOST="${LOCAL_REGISTRY}"
AIM_IMAGE="${AIM_IMAGE:-${LOCAL_REGISTRY}/aim-gfx1151-diffusiongemma-26b:0.11-therock}"
CATALOG_ONLY="${CATALOG_ONLY:-0}"

PROFILE_READY_TIMEOUT=120
DOWNLOAD_TIMEOUT=5400
POD_READY_TIMEOUT=1800

mem_avail_gib() {
  LANG=C free -g | awk '/^Mem:/{print $7}'
}

echo "=== 12-diffusiongemma-26b (namespace=${AIM_NAMESPACE}) ==="

echo ""
echo "--- Step -1: Stack startup hardening (Keycloak memory + pause inference) ---"
bash "$SCRIPT_DIR/ensure-stack-startup.sh"
bash "$SCRIPT_DIR/pause-aim-inference.sh" "${AIM_NAMESPACE}" || true

EAI_MIN_FREE_GB=95 check_disk_before_step "12-diffusiongemma-26b"
disk_report "12-diffusiongemma-26b-start"

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

if curl -sf "http://${LOCAL_REGISTRY}/v2/aim-gfx1151-diffusiongemma-26b/tags/list" 2>/dev/null \
  | python3 -c "import sys,json; t=json.load(sys.stdin).get('tags',[]); sys.exit(0 if '0.11-therock' in t else 1)" 2>/dev/null; then
  echo "Image already in local registry — skipping build."
else
  echo "Building ${AIM_IMAGE} ..."
  docker build -t "${AIM_IMAGE}" "${EAI_ROOT}/images/aim-gfx1151-diffusiongemma-26b/"
  echo "Pushing ${AIM_IMAGE} ..."
  docker push "${AIM_IMAGE}"
  echo "Image pushed successfully."
fi

echo "Pre-pulling image into RKE2 containerd..."
sudo /var/lib/rancher/rke2/bin/ctr \
  --address /run/k3s/containerd/containerd.sock \
  -n k8s.io images pull \
  --plain-http \
  "${AIM_IMAGE}" 2>/dev/null \
  || echo "WARN: ctr pre-pull failed (may already be present)"

echo "Smoke-testing image imports..."
docker run --rm \
  -e AIM_PROFILE_ID="${PROFILE_NAME}" \
  -e AIM_ID=google/diffusiongemma-26b \
  -e AIM_GPU_MODEL=R9700 -e AIM_GPU_COUNT=1 \
  -e AIM_METRIC=latency -e AIM_PRECISION=bf16 \
  "${AIM_IMAGE}" dry-run --format=json >/dev/null \
  && echo "Image dry-run smoke test: PASS" || echo "WARN: Image dry-run smoke test failed"

echo ""
echo "--- Step 1: R9700 accelerator label ---"
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
if kubectl get node "${NODE}" --show-labels 2>/dev/null | grep -q 'aim-accelerator.R9700'; then
  echo "R9700 label already present on ${NODE}."
else
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
  case "$PSTATUS" in
    Ready) break ;;
    NotAvailable)
      echo "ERROR: Profile NotAvailable — run: bash scripts/03b-gfx1151-aim-labels.sh"
      exit 1 ;;
  esac
  sleep 10; ELAPSED=$((ELAPSED + 10))
done

echo ""
echo "--- Step 3b: AIMClusterServiceTemplate + profile ConfigMap ---"
TSTATUS=$(kubectl get aimclusterservicetemplate "${PROFILE_NAME}" \
  -o jsonpath='{.status.status}' 2>/dev/null || echo "")
if [[ "$TSTATUS" == "Ready" ]]; then
  echo "  template already Ready — skipping template apply"
else
  kubectl apply -f "${MANIFEST_DIR}/aim-clusterservicetemplate.yaml" || true
fi
kubectl apply -f "${MANIFEST_DIR}/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml"
for _ in $(seq 1 30); do
  TSTATUS=$(kubectl get aimclusterservicetemplate "${PROFILE_NAME}" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  echo "  template status: ${TSTATUS:-pending}"
  [[ "$TSTATUS" == "Ready" ]] && break
  sleep 5
done

for _ in $(seq 1 24); do
  MSTATUS=$(kubectl get aimclustermodel "${MODEL_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="ClusterServiceTemplatesReady")].status}' 2>/dev/null || echo "")
  [[ "$MSTATUS" == "True" ]] && break
  kubectl annotate aimclustermodel "${MODEL_NAME}" \
    aim.eai.amd.com/reconcile="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  sleep 5
done

# Discovery job completes in ~10s; operator may take several minutes to mark template Ready.
DISC_JOB="discover-${PROFILE_NAME}"
for _ in $(seq 1 60); do
  TSTATUS=$(kubectl get aimclusterservicetemplate "${PROFILE_NAME}" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  [[ "$TSTATUS" == "Ready" ]] && break
  if kubectl get job "$DISC_JOB" -n aim-system &>/dev/null; then
    kubectl wait --for=condition=complete "job/${DISC_JOB}" -n aim-system --timeout=30s 2>/dev/null || true
  fi
  echo "  waiting for template Ready (current: ${TSTATUS:-pending})..."
  sleep 10
done

TSTATUS=$(kubectl get aimclusterservicetemplate "${PROFILE_NAME}" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
if [[ "$TSTATUS" != "Ready" ]]; then
  echo "  Template still ${TSTATUS:-?} — running fix-diffusiongemma-template-discovery.sh"
  bash "$SCRIPT_DIR/fix-diffusiongemma-template-discovery.sh" || true
fi

echo ""
echo "--- Step 3c: AIMRuntimeConfig/demo ---"
kubectl apply -f "${MANIFEST_DIR}/aim-runtimeconfig-demo.yaml"

if [[ "${CATALOG_ONLY}" == "1" ]]; then
  echo ""
  echo "CATALOG_ONLY=1: catalog CRs applied."
  bash "$SCRIPT_DIR/ensure-diffusiongemma-chattable.sh" || true
  TSTATUS=$(kubectl get aimclusterservicetemplate "${PROFILE_NAME}" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  if [[ "$TSTATUS" != "Ready" ]]; then
    echo "  Template status=${TSTATUS:-?} — discovery job may need a few minutes."
    echo "  If stuck Progressing: bash scripts/fix-diffusiongemma-template-discovery.sh"
    echo "  Or: kubectl delete lease aim-discovery-lock -n aim-system && kubectl rollout restart deploy/aim-engine-controller-manager -n aim-system"
  fi
  echo "  Deploy from AI Workbench: /demo/models/aim-catalog"
  disk_report "12-diffusiongemma-26b-catalog"
  exit 0
fi

echo ""
echo "--- Step 4: AIMService ---"
if kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" &>/dev/null; then
  COND=$(kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="DependenciesReachable")].reason}' 2>/dev/null || echo "")
  if [[ "$COND" == "InfrastructureError" ]]; then
    kubectl delete aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" --timeout=60s
    sleep 5
  fi
fi
kubectl apply -f "${MANIFEST_DIR}/aim-service.yaml"

echo ""
echo "--- Step 5: Waiting for weights download (up to ${DOWNLOAD_TIMEOUT}s) ---"
ELAPSED=0
PVC_NAME=""
while [[ $ELAPSED -lt $DOWNLOAD_TIMEOUT ]]; do
  PVC_NAME=$(kubectl get pvc -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -i "diffusiongemma\|diffusion-gemma" | awk '{print $1}' | head -1 || true)
  ART_NAME=$(kubectl get aimartifact -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
    | grep -i "diffusiongemma\|diffusion-gemma" | head -1 || true)

  if [[ -n "$ART_NAME" ]]; then
    ART_STATUS=$(kubectl get "$ART_NAME" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    ART_PROGRESS=$(kubectl get "$ART_NAME" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.progress}' 2>/dev/null || echo "")
    echo "  artifact: ${ART_NAME##*/} status=${ART_STATUS:-?} progress=${ART_PROGRESS:-?}% (${ELAPSED}s)"
    disk_report "download-progress"
    case "$ART_STATUS" in
      Succeeded|Ready) break ;;
      Failed)
        echo "ERROR: AIMArtifact download failed (check HF_TOKEN for gated Gemma model)."
        kubectl get "$ART_NAME" -n "${AIM_NAMESPACE}" -o yaml 2>/dev/null || true
        exit 1 ;;
    esac
  else
    SVCSTATUS=$(kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    echo "  aimservice=${SVCSTATUS:-pending} pvc=${PVC_NAME:-none} (${ELAPSED}s)"
    disk_report "download-wait"
  fi
  sleep 30; ELAPSED=$((ELAPSED + 30))
done

echo ""
echo "--- Step 6: Wait for InferenceService predictor ---"
bash "$SCRIPT_DIR/preflight-diffusiongemma-guard.sh"
ISVC_NAME=""
ELAPSED=0
while [[ $ELAPSED -lt 120 ]]; do
  ISVC_NAME=$(kubectl get inferenceservice -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -i "diffusiongemma" | awk '{print $1}' | head -1 || true)
  [[ -n "$ISVC_NAME" ]] && break
  ISVC_NAME=$(kubectl get inferenceservice -n "${AIM_NAMESPACE}" --no-headers 2>/dev/null \
    | grep -i "${SERVICE_NAME}" | awk '{print $1}' | head -1 || true)
  [[ -n "$ISVC_NAME" ]] && break
  sleep 10; ELAPSED=$((ELAPSED + 10))
done

if [[ -n "$ISVC_NAME" ]]; then
  ELAPSED=0
  while [[ $ELAPSED -lt $POD_READY_TIMEOUT ]]; do
    AVAIL=$(mem_avail_gib)
    GPU_WARNINGS=$( \
      (journalctl -k -b --since "3 minutes ago" --no-pager \
        | rg -i 'amdgpu_amdkfd_restore_userptr_worker|svm_range_restore_work.*hogged CPU|Failed to resume KFD|queue evicted' \
        || true) \
      | awk 'NF{c++} END{print c+0}' \
    )
    IS_STATUS=$(kubectl get inferenceservice "${ISVC_NAME}" -n "${AIM_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="PredictorReady")].status}' 2>/dev/null || echo "")
    echo "  PredictorReady=${IS_STATUS:-?} mem_avail=${AVAIL}GiB recent_gpu_warns=${GPU_WARNINGS} (${ELAPSED}s)"
    if [[ "${AVAIL}" -lt 15 ]] || [[ "${GPU_WARNINGS}" -gt 0 ]]; then
      echo "ERROR: Safety guard tripped while waiting for predictor."
      bash "$SCRIPT_DIR/pause-aim-inference.sh" "${AIM_NAMESPACE}" diffusiongemma || true
      exit 2
    fi
    [[ "$IS_STATUS" == "True" ]] && break
    sleep 30; ELAPSED=$((ELAPSED + 30))
  done
fi

echo ""
echo "--- Step 7: Post-deploy fixes ---"
bash "$SCRIPT_DIR/ensure-diffusiongemma-profile-mount.sh" "${AIM_NAMESPACE}"
bash "$SCRIPT_DIR/fix-aim-httproute-gateway.sh" "${AIM_NAMESPACE}" 2>/dev/null || true
bash "$SCRIPT_DIR/ensure-diffusiongemma-chattable.sh" || true

echo ""
echo "=== Summary ==="
echo "Model:   google/diffusiongemma-26B-A4B-it"
echo "Image:   ${AIM_IMAGE}"
echo "Profile: ${PROFILE_NAME}"
echo ""
echo "E2E:"
echo "  E2E_AIWB=1 E2E_DIFFUSIONGEMMA=1 pytest tests/e2e/test_aiwb_ui.py -k diffusiongemma -v"
echo ""
docker builder prune -af 2>/dev/null || true
disk_report "12-diffusiongemma-26b-end"
