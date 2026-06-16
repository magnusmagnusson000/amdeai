#!/usr/bin/env bash
# Remove the Qwen3.6-27B deployment weights to free disk space.
#
# Deletes:
#   - AIMService qwen3-6-27b in the demo namespace (stops inference, removes
#     InferenceService, predictor pod, HTTPRoute)
#   - The associated weights PVC(s) in the demo namespace (~104 GiB)
#
# Keeps (catalog profile remains intact for Workbench Deploy):
#   - AIMClusterModel     qwen-qwen3-6-27b
#   - AIMClusterProfile   qwen3-6-27b-r9700-gfx1151-latency
#   - AIMClusterServiceTemplate  qwen3-6-27b-r9700-gfx1151-latency
#   - AIMRuntimeConfig    default -n demo
#   - Container image in local registry
#
# Usage:
#   bash scripts/teardown-qwen-weights.sh
#   AIM_NAMESPACE=demo bash scripts/teardown-qwen-weights.sh
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
AIM_NAMESPACE="${AIM_NAMESPACE:-demo}"
SERVICE_NAME="qwen3-6-27b"

echo "=== teardown-qwen-weights: removing ${SERVICE_NAME} deployment from ${AIM_NAMESPACE} ==="
echo ""
echo "--- Pre-teardown disk usage ---"
df -h / | tail -1

# --- Step 1: Delete AIMService(s) for Qwen3.6-27B ---
echo ""
echo "--- Step 1: Delete Qwen3.6-27B AIMService(s) in ${AIM_NAMESPACE} ---"
QWEN_SERVICES=()
if kubectl get aimservice "${SERVICE_NAME}" -n "${AIM_NAMESPACE}" &>/dev/null; then
    QWEN_SERVICES+=("${SERVICE_NAME}")
fi
# Workbench Deploy creates wb-aim-* AIMServices — find by model ref
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    model="$(kubectl get aimservice "$name" -n "${AIM_NAMESPACE}" \
        -o jsonpath='{.spec.model.name}' 2>/dev/null || true)"
    if [[ "$model" == "qwen-qwen3-6-27b" ]] && [[ " ${QWEN_SERVICES[*]} " != *" $name "* ]]; then
        QWEN_SERVICES+=("$name")
    fi
done < <(kubectl get aimservice -n "${AIM_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [[ ${#QWEN_SERVICES[@]} -eq 0 ]]; then
    echo "  No Qwen3.6-27B AIMService found in ${AIM_NAMESPACE} — skipping."
else
    for svc in "${QWEN_SERVICES[@]}"; do
        echo "  Deleting AIMService/${svc}..."
        kubectl delete aimservice "${svc}" -n "${AIM_NAMESPACE}" \
            --wait=true --timeout=120s
    done
    echo "  AIMService(s) deleted."
fi

# --- Step 2: Delete orphaned InferenceService (if lingered) ---
echo ""
echo "--- Step 2: Clean up AIMTemplateCache / InferenceService ---"
for tc in $(kubectl get aimtemplatecache -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
            | grep -i "qwen3-6-27b\|qwen.*27" || true); do
    echo "  Removing ${tc}..."
    kubectl delete "${tc}" -n "${AIM_NAMESPACE}" --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true
done
for isvc in $(kubectl get inferenceservice -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
              | grep -i "qwen3-6-27b\|wb-aim" || true); do
    echo "  Removing ${isvc}..."
    kubectl delete "${isvc}" -n "${AIM_NAMESPACE}" \
        --ignore-not-found --force --grace-period=0 2>/dev/null || true
done

# --- Step 3: Delete weights PVCs ---
echo ""
echo "--- Step 3: Delete weights PVCs in ${AIM_NAMESPACE} ---"
PVC_DELETED=0
for pvc in $(kubectl get pvc -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
             | grep -i "qwen3-6-27b\|qwen.*3.*6.*27" || true); do
    NAME="${pvc#*/}"
    SIZE=$(kubectl get pvc "${NAME}" -n "${AIM_NAMESPACE}" \
           -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "?")
    echo "  Removing PVC ${NAME} (${SIZE})..."
    # Remove finalizers first in case the PVC is stuck
    kubectl patch pvc "${NAME}" -n "${AIM_NAMESPACE}" --type=json \
        -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    kubectl delete pvc "${NAME}" -n "${AIM_NAMESPACE}" \
        --ignore-not-found --force --grace-period=0 2>/dev/null || true
    PVC_DELETED=$((PVC_DELETED + 1))
done
if [[ $PVC_DELETED -eq 0 ]]; then
    echo "  No Qwen3.6-27B PVCs found — already clean."
fi

# --- Step 4: Remove AIMArtifact CRs (if any remain) ---
echo ""
echo "--- Step 4: Clean up AIMArtifact CRs ---"
for art in $(kubectl get aimartifact -n "${AIM_NAMESPACE}" -o name 2>/dev/null \
             | grep -i "qwen3-6-27b\|qwen.*27" || true); do
    echo "  Removing ${art}..."
    kubectl delete "${art}" -n "${AIM_NAMESPACE}" --ignore-not-found 2>/dev/null || true
done

# --- Step 5: Docker build cache prune ---
echo ""
echo "--- Step 5: Prune Docker build cache (reclaim overlay space) ---"
docker builder prune -af 2>/dev/null || true

echo ""
echo "--- Post-teardown disk usage ---"
df -h / | tail -1

echo ""
echo "=== teardown complete ==="
echo ""
echo "Kept (catalog profile intact for Workbench Deploy):"
echo "  AIMClusterModel     qwen-qwen3-6-27b"
echo "  AIMClusterProfile   qwen3-6-27b-r9700-gfx1151-latency"
echo "  AIMClusterServiceTemplate qwen3-6-27b-r9700-gfx1151-latency"
echo ""
echo "To re-deploy the 27B model later:"
echo "  CATALOG_ONLY=0 bash scripts/10-qwen3-6-27b.sh"
