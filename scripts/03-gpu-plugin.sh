#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "03-gpu-plugin"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "=== 03-gpu-plugin (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
mkdir -p "$EAI_BUILD_DIR"
fresh_git_clone https://github.com/ROCm/k8s-device-plugin.git "$EAI_BUILD_DIR/k8s-device-plugin"
cd "$EAI_BUILD_DIR/k8s-device-plugin"

log_source_tree "$EAI_BUILD_DIR/k8s-device-plugin"

force_docker_build localhost:32000/amd-gpu-device-plugin:latest .
docker push localhost:32000/amd-gpu-device-plugin:latest
if kubectl get nodes -o name 2>/dev/null | grep -q k3d; then
  export PATH="$HOME/.local/bin:$PATH"
  k3d image import localhost:32000/amd-gpu-device-plugin:latest -c eai
fi

kubectl delete ds amdgpu-device-plugin-daemonset -n kube-system --ignore-not-found
kubectl delete ds -n kube-system -l name=amdgpu-dp-ds --ignore-not-found 2>/dev/null || true

PLUGIN_IMAGE="localhost:32000/amd-gpu-device-plugin:latest"
PLUGIN_PULL="Always"
if kubectl get nodes -o name 2>/dev/null | grep -q k3d; then
  PLUGIN_IMAGE="amd-gpu-device-plugin:latest"
  PLUGIN_PULL="IfNotPresent"
fi

cat > k8s-ds-gfx1151.yaml << EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: amdgpu-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: amdgpu-dp-ds
  template:
    metadata:
      labels:
        name: amdgpu-dp-ds
    spec:
      priorityClassName: system-node-critical
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      containers:
      - name: amdgpu-dp-cntr
        image: ${PLUGIN_IMAGE}
        imagePullPolicy: ${PLUGIN_PULL}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: [ALL]
        env:
        - name: HSA_OVERRIDE_GFX_VERSION
          value: "11.5.1"
        volumeMounts:
        - name: dp-dir
          mountPath: /var/lib/kubelet/device-plugins
        - name: sys-dir
          mountPath: /sys
        - name: dev-dir
          mountPath: /dev
      volumes:
      - name: dp-dir
        hostPath:
          path: /var/lib/kubelet/device-plugins
      - name: sys-dir
        hostPath:
          path: /sys
      - name: dev-dir
        hostPath:
          path: /dev
EOF

kubectl apply -f k8s-ds-gfx1151.yaml
sleep 35

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl label node "${NODE}" \
  kaiwo/worker=true \
  kaiwo/topology-block=block-a \
  kaiwo/topology-rack=rack-a \
  kaiwo/gpu-model=radeon-8060s \
  kaiwo/nodepool=amd-gfx1151-1gpu \
  amd.com/gpu.present=true \
  feature.node.kubernetes.io/hardware-vendor.amd=true \
  --overwrite

kubectl get node -o custom-columns="NAME:.metadata.name,GPU:status.capacity.amd\.com/gpu"
echo "Call flow: $EAI_ROOT/docs/call-flows/03-k8s-device-plugin.md"

disk_report "03-k8s-device-plugin-done"
activate_venv && pytest "$EAI_ROOT/tests/build/test_k8s_device_plugin.py" -v --tb=short || true
