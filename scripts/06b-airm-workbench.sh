#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "06b-airm-workbench"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export DOMAIN=$(domain)

echo "=== 06b-airm-workbench (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
: "${HF_TOKEN:?Set HF_TOKEN for AI Workbench Helm install}"

helm uninstall airm -n airm 2>/dev/null || true
helm uninstall aiwb -n aiwb 2>/dev/null || true
sleep 5

helm upgrade --install airm oci://docker.io/amdenterpriseai/charts/airm \
  --version 1.0.2 \
  --namespace airm --create-namespace \
  --set global.domain="${DOMAIN}" \
  --set global.certOption=generate \
  --set keycloak.enabled=false \
  --set keycloak.externalUrl="https://keycloak.${DOMAIN}" \
  --wait --timeout 15m

helm upgrade --install aiwb oci://docker.io/amdenterpriseai/charts/aiwb \
  --version 1.0.3 \
  --namespace aiwb --create-namespace \
  --set global.domain="${DOMAIN}" \
  --set global.deploymentMode=combined \
  --set global.huggingFaceToken="${HF_TOKEN}" \
  --wait --timeout 15m

echo "=== AMD Resource Manager ==="
echo "URL: https://airmui.${DOMAIN}"
kubectl get secret airm-user-credentials -n airm \
  -o jsonpath='{.data.USER_PASSWORD}' 2>/dev/null | base64 -d; echo

echo "=== AMD AI Workbench ==="
echo "URL: https://aiwbui.${DOMAIN}"
kubectl get secret keycloak-credentials -n keycloak \
  -o jsonpath='{.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}' 2>/dev/null | base64 -d; echo

echo "Call flow: $EAI_ROOT/docs/call-flows/06b-airm-aiwb.md"
disk_report "06b-airm-workbench-done"
