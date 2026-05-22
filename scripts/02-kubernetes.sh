#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "02-kubernetes"
eai_backup_init "02-kubernetes"

kube_user_home() {
  if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
    getent passwd "$SUDO_USER" | cut -d: -f6
  else
    echo "$HOME"
  fi
}

kube_owner() {
  if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
    echo "$SUDO_USER"
  else
    echo "$USER"
  fi
}

kubectl_k3s() {
  sudo kubectl --kubeconfig="$K3S_ADMIN_KUBECONFIG" "$@"
}

export MY_IP=$(my_ip)
EAI_KUBE_USER_HOME="$(kube_user_home)"
export KUBECONFIG="${KUBECONFIG:-$EAI_KUBE_USER_HOME/.kube/config}"
K3S_ADMIN_KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EAI_STATE_DIR="${EAI_STATE_DIR:-$HOME/.cache/amdeai}"
EAI_REGISTRY_NODEPORT="${EAI_REGISTRY_NODEPORT:-32000}"

echo "=== 02-kubernetes (EAI_FORCE_REBUILD=${EAI_FORCE_REBUILD}) ==="
echo "kubeconfig target: $KUBECONFIG"
if eai_force_enabled; then
  echo "Force rebuild ON: existing k3s/k3d cluster may be removed and reinstalled."
  echo "Non-destructive run: EAI_FORCE_REBUILD=0 bash $0"
else
  echo "Force rebuild OFF: skip k3s uninstall when cluster is already healthy."
fi

preflight_kubernetes() {
  if [[ "${EAI_SKIP_REBOOT_CHECK:-0}" == "1" ]]; then
    echo "Skipping reboot preflight (EAI_SKIP_REBOOT_CHECK=1)."
    return 0
  fi
  local reasons=()
  [[ -f /var/run/reboot-required ]] && reasons+=("system pending reboot (/var/run/reboot-required)")
  [[ -f "$EAI_STATE_DIR/reboot-after-01-host-rocm" ]] && \
    reasons+=("01-host-rocm finished with REBOOT REQUIRED (run scripts/01-host-rocm.sh, reboot, then re-run this script)")
  if [[ ${#reasons[@]} -gt 0 ]]; then
    echo "ERROR: Reboot before installing Kubernetes:"
    printf '  - %s\n' "${reasons[@]}"
    echo "Override only if you accept unstable ROCm/GRUB state: EAI_SKIP_REBOOT_CHECK=1 bash $0"
    exit 1
  fi
}

check_registry_nodeport_free() {
  local port="$EAI_REGISTRY_NODEPORT"
  if ! ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
    return 0
  fi
  if ! eai_force_enabled && kubectl get svc registry -n kube-system \
      -o jsonpath="{.spec.ports[0].nodePort}" 2>/dev/null | grep -qx "${port}"; then
    echo "Port ${port} in use by existing kube-system/registry Service — OK."
    return 0
  fi
  echo "ERROR: port ${port} is already in use (registry NodePort)."
  ss -tlnp "sport = :${port}" 2>/dev/null || true
  exit 1
}

backup_kubeconfig() {
  if [[ -f "$EAI_KUBE_USER_HOME/.kube/config" ]]; then
    eai_backup_file "$EAI_KUBE_USER_HOME/.kube/config" kubeconfig
  fi
}

wait_for_k3s_api() {
  local label="${1:-k3s API}"
  echo "Waiting for ${label}..."
  for _ in $(seq 1 120); do
    if kubectl_k3s get --raw=/readyz &>/dev/null \
        || kubectl_k3s get nodes &>/dev/null; then
      echo "${label} is ready."
      return 0
    fi
    sleep 2
  done
  echo "ERROR: timed out waiting for ${label} (120 attempts)."
  sudo systemctl status k3s --no-pager -l 2>/dev/null | tail -25 || true
  exit 1
}

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

sync_k3s_kubeconfig() {
  local owner
  owner="$(kube_owner)"
  backup_kubeconfig
  mkdir -p "$EAI_KUBE_USER_HOME/.kube"
  sudo cp "$K3S_ADMIN_KUBECONFIG" "$EAI_KUBE_USER_HOME/.kube/config"
  sudo chown "${owner}:${owner}" "$EAI_KUBE_USER_HOME/.kube/config"
  # Keep 127.0.0.1 for local kubectl (stable across k3s restarts). MY_IP is in registries.yaml.
  if [[ "${EAI_KUBE_API_USE_NODE_IP:-0}" == "1" ]]; then
    sed -i "s|https://127.0.0.1:6443|https://${MY_IP}:6443|g" "$EAI_KUBE_USER_HOME/.kube/config"
    echo "kubeconfig API server set to ${MY_IP}:6443 (EAI_KUBE_API_USE_NODE_IP=1)."
  fi
  export KUBECONFIG="$EAI_KUBE_USER_HOME/.kube/config"
  echo "kubeconfig: $KUBECONFIG (context: $(kubectl config current-context 2>/dev/null || echo default))"
}

disable_swap_for_kubernetes() {
  eai_backup_file /etc/fstab fstab
  if swapon --show 2>/dev/null | grep -q .; then
    sudo swapoff -a 2>/dev/null || true
    echo "Swap disabled for current session (k3s requirement)."
  else
    echo "Swap already off."
  fi
  if grep -E '^\s*[^#].*\sswap\s' /etc/fstab 2>/dev/null | grep -q .; then
    sudo sed -i 's/^\([^#].*swap.*\)$/#\1/' /etc/fstab
    echo "Commented active swap entries in /etc/fstab (restore from backup if needed)."
  else
    echo "No active swap entries in /etc/fstab."
  fi
}

apply_registry_manifest() {
  check_registry_nodeport_free
  kubectl delete deploy registry -n kube-system --ignore-not-found
  kubectl apply -f - <<EOF
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
    nodePort: ${EAI_REGISTRY_NODEPORT}
EOF
}

configure_k3s_registries() {
  eai_backup_file /etc/rancher/k3s/registries.yaml registries.yaml 2>/dev/null || true
  sudo tee /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "localhost:${EAI_REGISTRY_NODEPORT}":
    endpoint:
      - "http://localhost:${EAI_REGISTRY_NODEPORT}"
  "${MY_IP}:${EAI_REGISTRY_NODEPORT}":
    endpoint:
      - "http://${MY_IP}:${EAI_REGISTRY_NODEPORT}"
EOF
  sudo systemctl restart k3s
  wait_for_k3s_api "k3s API after registry restart"
}

k3s_cluster_healthy() {
  command -v k3s &>/dev/null || return 1
  sudo systemctl is-active --quiet k3s 2>/dev/null || return 1
  kubectl_k3s get nodes &>/dev/null
}

# k3s v1.35+ kubelet rejects allowed-unsafe-sysctls=kernel.* (crash loop on 6443).
repair_k3s_kubelet_sysctls_if_needed() {
  local unit=/etc/systemd/system/k3s.service
  [[ -f "$unit" ]] || return 0
  if ! grep -qE 'allowed-unsafe-sysctls=.*kernel\.\*|allowed-unsafe-sysctls=.*kernel\.' "$unit"; then
    return 0
  fi
  echo "Repairing k3s: removing kernel.* from allowed-unsafe-sysctls (required on k3s v1.35+)."
  sudo sed -i \
    -e 's/--allowed-unsafe-sysctls=net\.\*,kernel\.\*/--allowed-unsafe-sysctls=net.*/g' \
    -e 's/allowed-unsafe-sysctls=net\.\*,kernel\.\*/allowed-unsafe-sysctls=net.*/g' \
    "$unit"
  sudo systemctl daemon-reload
  sudo systemctl restart k3s
  wait_for_k3s_api "k3s API after sysctl repair"
}

setup_k3d_cluster() {
  install_k3d_local
  check_registry_nodeport_free
  if eai_force_enabled; then
    k3d cluster delete eai 2>/dev/null || true
  fi
  if ! k3d cluster list 2>/dev/null | grep -q '\beai\b'; then
    k3d cluster create eai \
      --servers 1 \
      --registry-create "eai-registry:0.0.0.0:${EAI_REGISTRY_NODEPORT}" \
      --k3s-arg "--disable=traefik@server:0" \
      --k3s-arg "--disable=servicelb@server:0" \
      --k3s-arg "--kubelet-arg=allowed-unsafe-sysctls=net.*@server:0" \
      --k3s-arg "--kube-apiserver-arg=allow-privileged=true@server:0"
  fi
  mkdir -p "$EAI_KUBE_USER_HOME/.kube"
  k3d kubeconfig merge eai --kubeconfig-switch-context --kubeconfig-merge-default
  export KUBECONFIG="$EAI_KUBE_USER_HOME/.kube/config"
  echo "Using k3d cluster 'eai' (Docker-backed, registry on localhost:${EAI_REGISTRY_NODEPORT})"
}

setup_k3s_cluster() {
  disable_swap_for_kubernetes
  repair_k3s_kubelet_sysctls_if_needed
  force_k3s_reinstall

  if ! eai_force_enabled && k3s_cluster_healthy; then
    echo "k3s already healthy — skipping install (EAI_FORCE_REBUILD=0)."
    sync_k3s_kubeconfig
    apply_registry_manifest
    configure_k3s_registries
    return 0
  fi

  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --node-ip=${MY_IP} \
    --tls-san=${MY_IP} \
    --disable=traefik \
    --disable=servicelb \
    --kubelet-arg=--allowed-unsafe-sysctls=net.* \
    --kube-apiserver-arg=allow-privileged=true" sh -
  wait_for_k3s_api "k3s API after install"
  sync_k3s_kubeconfig
  apply_registry_manifest
  configure_k3s_registries
}

preflight_kubernetes

if sudo -n true 2>/dev/null; then
  setup_k3s_cluster
else
  echo "WARN: no passwordless sudo — using k3d (Docker) instead of host k3s"
  setup_k3d_cluster
fi

kubectl get nodes
echo "Call flow: $EAI_ROOT/docs/call-flows/02-k3s.md"
if [[ -n "${EAI_BACKUP_DIR:-}" ]]; then
  echo "Config backups: $EAI_BACKUP_DIR"
fi
disk_report "02-kubernetes-done"
