#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "05b-kaiwo"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="${PATH}:/usr/local/go/bin:${HOME}/go/bin"

echo "=== 05b-kaiwo (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
fresh_git_clone https://github.com/silogen/kaiwo.git "$EAI_BUILD_DIR/kaiwo"
cd "$EAI_BUILD_DIR/kaiwo"
log_source_tree "$EAI_BUILD_DIR/kaiwo"

kubectl apply -f https://github.com/project-codeflare/appwrapper/releases/latest/download/install.yaml

IMG=localhost:32000/kaiwo-operator:latest
make docker-build IMG="${IMG}"
docker push "${IMG}"
if kubectl get nodes -o name 2>/dev/null | grep -q k3d; then
  export PATH="$HOME/.local/bin:$PATH"
  k3d image import "${IMG}" -c eai
  IMG="kaiwo-operator:latest"
fi

make uninstall 2>/dev/null || true
make install
make deploy IMG="${IMG}"

rm -f "${HOME}/go/bin/kaiwo"
go build -o "${HOME}/go/bin/kaiwo" ./cmd/kaiwo/
"${HOME}/go/bin/kaiwo" version

kubectl apply -f - << 'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: amd-gfx1151
spec:
  nodeLabels:
    kaiwo/gpu-model: radeon-8060s
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: cluster-queue
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: [amd.com/gpu, cpu, memory]
    flavors:
    - name: amd-gfx1151
      resources:
      - name: amd.com/gpu
        nominalQuota: 1
      - name: cpu
        nominalQuota: 11
      - name: memory
        nominalQuota: 100Gi
EOF

kubectl get pods -n kaiwo-system
echo "Call flow: $EAI_ROOT/docs/call-flows/05b-kaiwo.md"
disk_report "05b-kaiwo-done"
activate_venv && pytest "$EAI_ROOT/tests/build/test_kaiwo.py" -v --tb=short || true
