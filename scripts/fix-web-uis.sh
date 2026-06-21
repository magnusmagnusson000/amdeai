#!/usr/bin/env bash
# Recover AI Workbench + AIRM web UIs after disk-pressure evictions, Keycloak OOM,
# or Docker Hub rate limits (common after large local image builds, e.g. Qwen AIM).
#
# Usage:
#   bash scripts/fix-web-uis.sh
#   DOCKERHUB_USER=... DOCKERHUB_TOKEN=... bash scripts/fix-web-uis.sh
#
# See also: docs/BLOOM_GFX1151_INSTALL.md (Troubleshooting)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/stack-startup.sh
source "$SCRIPT_DIR/lib/stack-startup.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
DOMAIN="${DOMAIN:-$(grep -E '^DOMAIN:' "$EAI_ROOT/bloom-gfx1151.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || domain)}"
NODE_IP="$(my_ip)"
CRI_SOCKET="${CRI_SOCKET:-unix:///run/k3s/containerd/containerd.sock}"
CRICTL="${CRICTL:-/var/lib/rancher/rke2/bin/crictl}"
CTR="${CTR:-/var/lib/rancher/rke2/bin/ctr}"

echo "=== fix-web-uis (domain=${DOMAIN}) ==="

free_disk_if_low() {
  local free_gb
  free_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  echo "Root filesystem: ${free_gb} GiB free"
  if [[ "$free_gb" -lt 40 ]]; then
    echo "Low disk — pruning Docker build cache, unused volumes, and local aim-base image..."
    docker builder prune -af 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true
    docker rmi amdenterpriseai/aim-base:0.11 2>/dev/null || true
    free_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    echo "After prune: ${free_gb} GiB free"
    if [[ "$free_gb" -lt 25 ]]; then
      echo "WARNING: still low on disk. Large consumers on this host:"
      echo "  ~/projects/oracle-archive (~168 GiB archive parts)"
      echo "  /opt/local-path-provisioner (~114 GiB — Qwen model PVCs)"
    fi
  fi
}

kyverno_webhook_failopen() {
  if kubectl get pods -n kyverno --field-selector=status.phase=Running 2>/dev/null | grep -q kyverno; then
    return 0
  fi
  echo "Kyverno down — setting validating webhooks to failurePolicy=Ignore..."
  for wh in $(kubectl get validatingwebhookconfiguration -o name 2>/dev/null | grep kyverno || true); do
    kubectl patch "$wh" --type=json \
      -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]' 2>/dev/null || true
  done
}

clear_disk_pressure_taint() {
  if ! kubectl describe node 2>/dev/null | grep -q 'disk-pressure:NoSchedule'; then
    return 0
  fi
  echo "Node has disk-pressure taint — restarting rke2-server to trigger image GC..."
  sudo systemctl restart rke2-server
  for _ in $(seq 1 60); do
    kubectl get nodes &>/dev/null || true
    if ! kubectl describe node 2>/dev/null | grep -q 'disk-pressure:NoSchedule'; then
      echo "Disk-pressure taint cleared."
      return 0
    fi
    sleep 5
  done
  echo "WARN: disk-pressure taint still present after rke2 restart."
}

wait_for_cluster_auth() {
  if ! kubectl get deployment cluster-auth -n cluster-auth &>/dev/null; then
    return 0
  fi
  echo "Waiting for cluster-auth (envoy ext-auth — required for HTTPS routes)..."
  kubectl wait deployment/cluster-auth -n cluster-auth --for=condition=Available --timeout=300s 2>/dev/null \
    || kubectl rollout status deployment/cluster-auth -n cluster-auth --timeout=300s
}

configure_rke2_dockerhub_auth() {
  local registries_file="/etc/rancher/rke2/registries.yaml"
  [[ -f "$registries_file" ]] || return 0
  [[ -n "${DOCKERHUB_USER:-}" && -n "${DOCKERHUB_TOKEN:-}" ]] || {
    echo "Tip: set DOCKERHUB_USER + DOCKERHUB_TOKEN to restore aiwb-api/airm-api pulls after rate limits."
    return 0
  }
  if grep -q 'docker.io' "$registries_file" 2>/dev/null && grep -q 'auth:' "$registries_file" 2>/dev/null; then
    echo "RKE2 registries.yaml already has docker.io auth."
    return 0
  fi
  echo "Appending Docker Hub credentials to ${registries_file}..."
  sudo tee -a "$registries_file" <<EOF

configs:
  "docker.io":
    auth:
      username: ${DOCKERHUB_USER}
      password: ${DOCKERHUB_TOKEN}
EOF
  echo "Restarting rke2-server for registry config..."
  sudo systemctl restart rke2-server
  for _ in $(seq 1 60); do
    kubectl get nodes &>/dev/null && break
    sleep 5
  done
}

import_image_to_containerd() {
  local image="$1"
  if [[ ! -x "$CTR" ]]; then
    return 0
  fi
  export CONTAINER_RUNTIME_ENDPOINT="$CRI_SOCKET"
  if sudo -E "$CRICTL" images 2>/dev/null | grep -q "${image##*/}"; then
    echo "Already in containerd: ${image}"
    return 0
  fi
  echo "Pulling ${image} via Docker and importing to containerd..."
  docker pull "$image"
  docker save "$image" | sudo "$CTR" --address "${CRI_SOCKET#unix://}" -n k8s.io images import -
}

pull_critical_api_images() {
  local images=(
    "amdenterpriseai/aiwb-api:1.1.9"
    "amdenterpriseai/airm-api:1.1.9"
  )
  for img in "${images[@]}"; do
    import_image_to_containerd "$img" || echo "WARN: could not import ${img}"
  done
  for entry in aiwb:aiwb-api airm:airm-api; do
    IFS=: read -r namespace name <<<"$entry"
    kubectl rollout restart "deployment/${name}" -n "$namespace" 2>/dev/null || true
  done
}

smoke_test() {
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" "https://kc.${DOMAIN}/" || echo "000")
  echo "Keycloak (kc.${DOMAIN}): HTTP ${code} (expect 302 or 200)"
  code=$(curl -sk -o /dev/null -w "%{http_code}" "https://aiwbui.${DOMAIN}/" || echo "000")
  echo "AI Workbench (aiwbui.${DOMAIN}): HTTP ${code} (expect 307 or 200)"
  code=$(curl -sk -o /dev/null -w "%{http_code}" "https://airmui.${DOMAIN}/" || echo "000")
  echo "AIRM (airmui.${DOMAIN}): HTTP ${code} (expect 307 or 200)"
  if curl -sk "https://aiwbui.${DOMAIN}/api/auth/providers" 2>/dev/null | grep -q keycloak; then
    echo "NextAuth Keycloak provider: OK"
  else
    echo "WARN: NextAuth providers endpoint unhealthy"
    return 1
  fi
}

free_disk_if_low
kyverno_webhook_failopen
clear_disk_pressure_taint
stack_startup_patch_keycloak_memory
configure_rke2_dockerhub_auth
stack_startup_cleanup_evicted_pods
if [[ -n "${DOCKERHUB_USER:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
  pull_critical_api_images
fi
stack_startup_wait_for_keycloak 300
wait_for_cluster_auth
smoke_test

echo ""
echo "Sign in: https://aiwbui.${DOMAIN}/ → Sign in with Keycloak → devuser@${DOMAIN}"
echo "DevUser password: kubectl get secret airm-realm-credentials -n keycloak -o jsonpath='{.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}' | base64 -d; echo"
echo "AIM catalog: https://aiwbui.${DOMAIN}/demo/models/aim-catalog"
disk_report "fix-web-uis-done"
