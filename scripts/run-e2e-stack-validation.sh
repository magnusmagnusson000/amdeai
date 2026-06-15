#!/usr/bin/env bash
# Sequential Playwright validation: cluster health → Keycloak login → Qwen catalog Deploy dialog.
#
# Does NOT run the destructive full-deploy test (E2E_QWEN_DEPLOY=1). For one-time confirm deploy:
#   E2E_QWEN_DEPLOY=1 pytest tests/e2e/test_aiwb_ui.py::test_qwen_deploy_confirm_full -v -s
#
# Usage:
#   bash scripts/run-e2e-stack-validation.sh
#   SKIP_QWEN_CATALOG_PREP=1 bash scripts/run-e2e-stack-validation.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
EAI_VENV="${EAI_VENV:-/home/magnus/projects/venvs/amd}"

echo "=== E2E stack validation (cluster + Web UI + Qwen catalog) ==="

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl cluster-info failed — bring up Bloom/RKE2 first."
  echo "  See: docs/BLOOM_GFX1151_INSTALL.md"
  exit 1
fi

DOMAIN_VAL="$(domain)"
echo "Domain: ${DOMAIN_VAL}"

# Recover UIs if HTTPS returns 403 (disk-pressure / Keycloak OOM)
for host in "aiwbui.${DOMAIN_VAL}" "airmui.${DOMAIN_VAL}"; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${host}/" || echo "000")
  if [[ "$code" == "403" || "$code" == "502" || "$code" == "503" ]]; then
    echo "HTTPS ${code} on ${host} — running fix-web-uis.sh..."
    bash "$SCRIPT_DIR/fix-web-uis.sh"
    break
  fi
done

if [[ "${SKIP_QWEN_CATALOG_PREP:-0}" != "1" ]]; then
  TEMPLATE="qwen3-6-27b-r9700-gfx1151-latency"
  TSTATUS=$(kubectl get aimclusterservicetemplate "$TEMPLATE" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  if [[ "$TSTATUS" != "Ready" ]]; then
    echo "Qwen catalog template not Ready (${TSTATUS:-missing}) — CATALOG_ONLY=1 scripts/10-qwen3-6-27b.sh"
    CATALOG_ONLY=1 bash "$SCRIPT_DIR/10-qwen3-6-27b.sh"
  else
    echo "Qwen catalog template Ready."
  fi
fi

if [[ -f "${EAI_VENV}/bin/activate" ]]; then
  # shellcheck source=/dev/null
  source "${EAI_VENV}/bin/activate"
fi

pip install -q -r "$EAI_ROOT/tests/requirements.txt"
playwright install chromium 2>/dev/null || true

echo ""
echo "--- pytest (ordered) ---"
export E2E_STACK=1 E2E_AIWB=1 E2E_AIRM=1
pytest "$EAI_ROOT/tests/e2e/test_stack_health.py" \
  "$EAI_ROOT/tests/e2e/test_aiwb_ui.py" \
  "$EAI_ROOT/tests/e2e/test_airm_ui.py" \
  -v --order-scope=session \
  -k "stack_cluster or stack_qwen or stack_https or keycloak_login or airm_login or aim_catalog_shows_qwen or deploy_qwen_model"

echo ""
echo "=== Stack validation PASS ==="
echo "One-time full Deploy confirm (destructive, ~52 GiB download):"
echo "  E2E_QWEN_DEPLOY=1 pytest tests/e2e/test_aiwb_ui.py::test_qwen_deploy_confirm_full -v -s"
