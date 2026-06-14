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

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
DOMAIN="${DOMAIN:-$(domain)}"
NODE_IP="$(my_ip)"
CRI_SOCKET="${CRI_SOCKET:-unix:///run/k3s/containerd/containerd.sock}"
CRICTL="${CRICTL:-/var/lib/rancher/rke2/bin/crictl}"
CTR="${CTR:-/var/lib/rancher/rke2/bin/ctr}"

echo "=== fix-web-uis (domain=${DOMAIN}) ==="

free_disk_if_low() {
  local free_gb
  free_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  echo "Root filesystem: ${free_gb} GiB free"
  if [[ "$free_gb" -lt 25 ]]; then
    echo "Low disk — pruning Docker build cache and unused volumes..."
    docker builder prune -af 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true
    free_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    echo "After prune: ${free_gb} GiB free"
  fi
}

patch_keycloak_memory() {
  if ! kubectl get deployment keycloak -n keycloak &>/dev/null; then
    echo "Keycloak deployment not found — skipping memory patch."
    return 0
  fi
  local limit
  limit=$(kubectl get deployment keycloak -n keycloak \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
  if [[ "$limit" == "4Gi" ]]; then
    echo "Keycloak memory limit already 4Gi."
    return 0
  fi
  echo "Patching Keycloak memory limit 2Gi → 4Gi (prevents OOM during realm import)..."
  kubectl patch deployment keycloak -n keycloak --type=json \
    -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"4Gi"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"2Gi"}
    ]'
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

cleanup_evicted_pods() {
  echo "Removing evicted / failed pods in keycloak, aiwb, airm..."
  for ns in keycloak aiwb airm; do
    kubectl get pods -n "$ns" --field-selector=status.phase=Failed -o name 2>/dev/null \
      | xargs -r kubectl delete -n "$ns" 2>/dev/null || true
  done
}

wait_for_keycloak() {
  echo "Waiting for Keycloak readiness..."
  kubectl wait deployment/keycloak -n keycloak --for=condition=Available --timeout=300s 2>/dev/null \
    || kubectl rollout status deployment/keycloak -n keycloak --timeout=300s
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
patch_keycloak_memory
configure_rke2_dockerhub_auth
cleanup_evicted_pods
if [[ -n "${DOCKERHUB_USER:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
  pull_critical_api_images
fi
wait_for_keycloak
smoke_test

echo ""
echo "Sign in: https://aiwbui.${DOMAIN} → Sign in with Keycloak → devuser@${DOMAIN}"
echo "DevUser password: kubectl get secret airm-realm-credentials -n keycloak -o jsonpath='{.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}' | base64 -d; echo"
echo "AIM catalog: https://aiwbui.${DOMAIN}/demo/models/aim-catalog"
disk_report "fix-web-uis-done"
