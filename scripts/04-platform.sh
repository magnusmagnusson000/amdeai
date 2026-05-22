#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "04-platform"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export MY_IP=$(my_ip)

echo "=== 04-platform (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="

helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ 2>/dev/null || true
# KServe: upstream helm repo URL is unstable; use release manifest when Helm fails
KSERVE_MANIFEST="${KSERVE_MANIFEST:-https://github.com/kserve/kserve/releases/download/v0.15.0/kserve.yaml}"

force_helm_reinstall cert-manager jetstack/cert-manager cert-manager \
  --set crds.enabled=true --wait --timeout 5m

force_helm_reinstall metallb metallb/metallb metallb-system \
  --version 0.14.9 \
  --set prometheus.serviceMonitor.enabled=false \
  --set frrk8s.enabled=false \
  --wait --timeout 5m

kubectl apply -f - << EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
  - ${MY_IP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-advert
  namespace: metallb-system
EOF

if kubectl get nodes -o name 2>/dev/null | grep -q k3d; then
  echo "k3d cluster: skipping Longhorn (needs multi-path host mounts); using default local-path StorageClass"
  helm uninstall longhorn -n longhorn-system 2>/dev/null || true
  kubectl get storageclass
else
  force_helm_reinstall longhorn longhorn/longhorn longhorn-system \
    --set defaultSettings.defaultReplicaCount=1 \
    --set defaultSettings.storageMinimalAvailablePercentage=10 \
    --wait --timeout 20m
  kubectl patch storageclass longhorn \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
fi

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

kubectl delete -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.17.0/manifests.yaml --ignore-not-found 2>/dev/null || true
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.17.0/manifests.yaml
kubectl wait deploy/kueue-controller-manager -n kueue-system \
  --for=condition=available --timeout=5m

force_helm_reinstall kuberay-operator kuberay/kuberay-operator ray-system \
  --wait --timeout 5m

kubectl delete ns kserve --ignore-not-found --timeout=120s 2>/dev/null || true
sleep 3
if helm repo add kserve https://kserve.github.io/helm-charts/ 2>/dev/null && helm search repo kserve/kserve -l 2>/dev/null | grep -q kserve; then
  force_helm_reinstall kserve kserve/kserve kserve \
    --set kserve.controller.gateway.ingressGateway.className=kgateway \
    --wait --timeout 10m
else
  echo "Installing KServe from release manifest: ${KSERVE_MANIFEST}"
  kubectl apply -f "${KSERVE_MANIFEST}" || echo "WARN: KServe manifest apply failed — continue without KServe"
fi

kubectl get pods -A | grep -vE 'Running|Completed|NAMESPACE' || echo "Platform pods OK"
echo "Call flow: $EAI_ROOT/docs/call-flows/04-platform.md"
disk_report "04-platform-done"
