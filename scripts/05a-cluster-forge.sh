#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "05a-cluster-forge"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="${PATH}:/usr/local/go/bin:${HOME}/go/bin"
export MY_IP=$(my_ip)
export DOMAIN=$(domain)

echo "=== 05a-cluster-forge (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
fresh_git_clone https://github.com/silogen/cluster-forge.git "$EAI_BUILD_DIR/cluster-forge"
cd "$EAI_BUILD_DIR/cluster-forge"
log_source_tree "$EAI_BUILD_DIR/cluster-forge"

if [[ ! -x scripts/bootstrap.sh ]]; then
  echo "ERROR: scripts/bootstrap.sh not found — cluster-forge layout may have changed"
  exit 1
fi

# New cluster-forge uses bootstrap.sh + sources/ (no local go smelt/cast)
if eai_force_enabled; then
  ./scripts/bootstrap.sh "${DOMAIN}" --cluster-size=small \
    --disabled-apps=airm,airm-infra-keycloak,airm-infra-cnpg,airm-infra-minio 2>&1 || \
    echo "bootstrap may need Gitea cert acceptance — re-run after trusting https://gitea.${DOMAIN}"
fi

echo "Call flow: $EAI_ROOT/docs/call-flows/05a-cluster-forge.md"
disk_report "05a-cluster-forge-done"
activate_venv && pytest "$EAI_ROOT/tests/build/test_cluster_forge.py" -v --tb=short || true
