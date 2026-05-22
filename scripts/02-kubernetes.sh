#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "02-kubernetes"
export MY_IP=$(my_ip)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "=== 02-kubernetes (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="

install_k3d_local() {
  mkdir -p "$HOME/.local/bin"
  if [[ ! -x "$HOME/.local/bin/k3d" ]]; then
    K3D_VER=v5.8.3
    curl -fsSL "https://github.com/k3d-io/k3d/releases/download/${K3D_VER}/k3d-linux-amd64" \
      -o "$HOME/.local/bin/k3d"
    chmod +x "$HOME/.local/bin/k3d"
  fi
  export PATH="$HOME/.local/bin:$PATH"
}

setup_k3d_cluster() {
  install_k3d_local
  if eai_force_enabled; then
    k3d cluster delete eai 2>/dev/null || true
  fi
  if ! k3d cluster list 2>/dev/null | grep -q '\beai\b'; then
    k3d cluster create eai \
      --servers 1 \
      --registry-create "eai-registry:0.0.0.0:32000" \
      --k3s-arg "--disable=traefik@server:0" \
      --k3s-arg "--disable=servicelb@server:0" \
      --k3s-arg "--kubelet-arg=allowed-unsafe-sysctls=net.*,kernel.*@server:0" \
      --k3s-arg "--kube-apiserver-arg=allow-privileged=true@server:0"
  fi
  mkdir -p "$HOME/.kube"
  k3d kubeconfig merge eai --kubeconfig-switch-context --kubeconfig-merge-default
  export KUBECONFIG="$HOME/.kube/config"
  echo "Using k3d cluster 'eai' (Docker-backed, registry on localhost:32000)"
}

setup_k3s_cluster() {
  sudo swapoff -a 2>/dev/null || true
  sudo sed -i 's/^\(.*swap.*\)$/#\1/' /etc/fstab 2>/dev/null || true
  force_k3s_reinstall
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --node-ip=${MY_IP} \
    --tls-san=${MY_IP} \
    --disable=traefik \
    --disable=servicelb \
    --kubelet-arg=--allowed-unsafe-sysctls=net.*,kernel.* \
    --kube-apiserver-arg=allow-privileged=true" sh -
  for i in $(seq 1 90); do
    sudo kubectl get nodes &>/dev/null && break
    sleep 2
  done
  rm -f ~/.kube/config
  mkdir -p ~/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown "$USER:$USER" ~/.kube/config
  sed -i "s/127.0.0.1/${MY_IP}/g" ~/.kube/config
  export KUBECONFIG=~/.kube/config

  kubectl delete deploy registry -n kube-system --ignore-not-found
  kubectl apply -f - << 'EOF'
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
EOF
  sudo tee /etc/rancher/k3s/registries.yaml << EOF
mirrors:
  "localhost:32000":
    endpoint:
      - "http://localhost:32000"
  "${MY_IP}:32000":
    endpoint:
      - "http://${MY_IP}:32000"
EOF
  sudo systemctl restart k3s
  sleep 25
}

if sudo -n true 2>/dev/null; then
  setup_k3s_cluster
else
  echo "WARN: no passwordless sudo — using k3d (Docker) instead of host k3s"
  setup_k3d_cluster
fi

kubectl get nodes
echo "Call flow: $EAI_ROOT/docs/call-flows/02-k3s.md"
disk_report "02-kubernetes-done"
