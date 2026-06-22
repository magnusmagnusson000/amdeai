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

if [[ "${E2E_PHI4:-0}" == "1" ]]; then
  echo "E2E_PHI4=1 — ensuring DiffusionGemma inference is paused before Phi-4 tests..."
  bash "$SCRIPT_DIR/ensure-diffusiongemma-paused.sh" demo default || true
fi

# Patch Keycloak memory before JVM cold-start can OOM its 2Gi cgroup (gfx1151 boot freeze).
bash "$SCRIPT_DIR/ensure-stack-startup.sh" || {
  echo "WARN: ensure-stack-startup failed — continuing (UIs may be unhealthy)."
}

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

if [[ "${SKIP_PHI4_CATALOG_PREP:-0}" != "1" ]] && [[ "${E2E_PHI4:-0}" == "1" ]]; then
  PHI_TEMPLATE="phi-4-14b-r9700-gfx1151-latency"
  PHI_STATUS=$(kubectl get aimclusterservicetemplate "$PHI_TEMPLATE" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  if [[ "$PHI_STATUS" != "Ready" ]]; then
    echo "Phi-4 catalog not Ready — pausing DiffusionGemma, then CATALOG_ONLY=1 scripts/13-phi-4-14b.sh"
    bash "$SCRIPT_DIR/ensure-diffusiongemma-paused.sh" demo default || true
    CATALOG_ONLY=1 bash "$SCRIPT_DIR/13-phi-4-14b.sh"
  fi
fi

if [[ "${SKIP_DIFFUSIONGEMMA_CATALOG_PREP:-0}" != "1" ]] && [[ "${E2E_DIFFUSIONGEMMA:-0}" == "1" ]]; then
  DG_TEMPLATE="diffusiongemma-26b-r9700-gfx1151-latency"
  DG_STATUS=$(kubectl get aimclusterservicetemplate "$DG_TEMPLATE" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "")
  if [[ "$DG_STATUS" != "Ready" ]]; then
    echo "DiffusionGemma catalog not Ready — CATALOG_ONLY=1 scripts/12-diffusiongemma-26b.sh"
    CATALOG_ONLY=1 bash "$SCRIPT_DIR/12-diffusiongemma-26b.sh"
    bash "$SCRIPT_DIR/fix-diffusiongemma-template-discovery.sh" || true
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
echo ""
echo "DiffusionGemma catalog + Deploy dialog (non-destructive):"
echo "  E2E_STACK=1 E2E_AIWB=1 E2E_DIFFUSIONGEMMA=1 pytest tests/e2e/test_aiwb_ui.py -k diffusiongemma -v"
echo "One-time DiffusionGemma full deploy:"
echo "  E2E_DIFFUSIONGEMMA_DEPLOY=1 pytest tests/e2e/test_aiwb_ui.py::test_diffusiongemma_deploy_confirm_full -v -s"
echo ""
echo "Phi-4 14B catalog + Deploy dialog (non-destructive):"
echo "  E2E_STACK=1 E2E_AIWB=1 E2E_PHI4=1 pytest tests/e2e/test_aiwb_ui.py -k phi4 -v"
echo "One-time Phi-4 full deploy (~28 GiB download; pauses DiffusionGemma first):"
echo "  E2E_PHI4_DEPLOY=1 pytest tests/e2e/test_aiwb_ui.py::test_phi4_deploy_confirm_full -v -s"
