#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "06a-aim-engine"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "=== 06a-aim-engine (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
fresh_git_clone https://github.com/amd-enterprise-ai/aim-engine.git "$EAI_BUILD_DIR/aim-engine"
cd "$EAI_BUILD_DIR/aim-engine"
log_source_tree "$EAI_BUILD_DIR/aim-engine"

make crds
make helm

helm uninstall aim-engine -n aim-system 2>/dev/null || true
kubectl delete -f dist/crds.yaml --ignore-not-found 2>/dev/null || true
sleep 2
kubectl apply -f dist/crds.yaml
kubectl wait --for=condition=Established crd --all --timeout=120s 2>/dev/null || true

helm upgrade --install aim-engine ./dist/chart \
  --namespace aim-system --create-namespace \
  --set clusterRuntimeConfig.enable=true \
  --set clusterRuntimeConfig.spec.routing.enabled=true \
  --wait --timeout 10m

kubectl get pods -n aim-system
echo "Call flow: $EAI_ROOT/docs/call-flows/06a-aim-engine.md"
disk_report "06a-aim-engine-done"
activate_venv && pytest "$EAI_ROOT/tests/build/test_aim_engine.py" -v --tb=short || true
