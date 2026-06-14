#!/usr/bin/env bash
# Migrate cluster UIs from <ip>.nip.io to hostname-based DOMAIN (stable across DHCP).
#
# Updates: cluster-domain ConfigMap, cluster-tls wildcard cert, ArgoCD app domain
# parameters, MetalLB pool, Gateway LB address, CoreDNS rewrite, /etc/hosts, and
# AIWB/AIRM/Keycloak env via ArgoCD sync.
#
# Usage:
#   bash scripts/migrate-domain-hostname.sh
#   DOMAIN=my-host bash scripts/migrate-domain-hostname.sh   # override hostname
#
# See also: scripts/fix-node-ip.sh (refreshes LB IP + /etc/hosts on DHCP changes)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
OLD_DOMAIN="${OLD_DOMAIN:-192.168.32.13.nip.io}"
NEW_DOMAIN="${DOMAIN:-$(domain)}"
NODE_IP="$(my_ip)"

echo "=== migrate-domain-hostname ==="
echo "OLD_DOMAIN : ${OLD_DOMAIN}"
echo "NEW_DOMAIN : ${NEW_DOMAIN}"
echo "NODE_IP    : ${NODE_IP}"
echo ""

generate_cluster_tls() {
  local domain="$1"
  local ip="$2"
  local tmpdir
  tmpdir=$(mktemp -d)
  local cnf="${tmpdir}/openssl.cnf"
  cat >"${cnf}" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${domain}
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
DNS.3 = k8s.${domain}
DNS.4 = kc.${domain}
DNS.5 = keycloak.${domain}
IP.1 = ${ip}
IP.2 = 127.0.0.1
EOF
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "${tmpdir}/tls.key" -out "${tmpdir}/tls.crt" \
    -config "${cnf}" -extensions v3_req
  echo "${tmpdir}"
}

apply_cluster_tls_secret() {
  local ns="$1"
  local crt="$2"
  local key="$3"
  kubectl create secret tls cluster-tls \
    --cert="${crt}" --key="${key}" \
    -n "${ns}" --dry-run=client -o yaml | kubectl apply -f -
}

patch_argocd_app_param() {
  local app="$1"
  local param="$2"
  local value="$3"
  if ! kubectl get application "${app}" -n argocd &>/dev/null; then
    echo "  skip ${app} (not found)"
    return 0
  fi
  kubectl patch application "${app}" -n argocd --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/source/helm/parameters\",\"value\":$(kubectl get application "${app}" -n argocd -o json | python3 -c "
import json,sys
app=json.load(sys.stdin)
params=app['spec']['source'].get('helm',{}).get('parameters',[])
found=False
for p in params:
    if p.get('name')=='${param}':
        p['value']='${value}'
        found=True
if not found:
    params.append({'name':'${param}','value':'${value}'})
print(json.dumps(params))
")}]" 2>/dev/null
  echo "  patched ${app} ${param}=${value}"
}

sync_argocd_apps() {
  local apps=("$@")
  for app in "${apps[@]}"; do
    kubectl get application "${app}" -n argocd &>/dev/null || continue
    echo "  syncing ${app}..."
    kubectl patch application "${app}" -n argocd \
      --type=merge -p '{"operation":{"initiatedBy":{"username":"migrate-domain"},"sync":{}}}' 2>/dev/null \
      || argocd app sync "${app}" --async 2>/dev/null \
      || kubectl annotate application "${app}" -n argocd \
        argocd.argoproj.io/refresh=hard --overwrite
  done
}

update_cluster_hosts() {
  bash "$SCRIPT_DIR/update-cluster-hosts.sh" "${NODE_IP}" "${NEW_DOMAIN}"
}

update_metallb_pool() {
  if ! kubectl get ipaddresspool local-pool -n metallb-system &>/dev/null; then
    echo "  skip MetalLB (local-pool not found)"
    return 0
  fi
  kubectl patch ipaddresspool local-pool -n metallb-system --type=merge \
    -p "{\"spec\":{\"addresses\":[\"${NODE_IP}/32\"]}}"
  echo "  MetalLB local-pool -> ${NODE_IP}/32"
}

update_gateway_lb() {
  if ! kubectl get gateway https -n envoy-gateway-system &>/dev/null; then
    echo "  skip Gateway (not found)"
    return 0
  fi
  kubectl patch gateway https -n envoy-gateway-system --type=merge \
    -p "{\"spec\":{\"addresses\":[{\"type\":\"IPAddress\",\"value\":\"${NODE_IP}\"}]}}"
  local svc
  svc=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=https -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${svc}" ]]; then
    kubectl annotate svc "${svc}" -n envoy-gateway-system \
      metallb.universe.tf/loadBalancerIPs="${NODE_IP}" --overwrite 2>/dev/null || true
  fi
  echo "  Gateway LB address -> ${NODE_IP}"
}

update_cluster_domain_cm() {
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-domain
  namespace: default
data:
  DOMAIN: "${NEW_DOMAIN}"
  use-cert-manager: "false"
EOF
  echo "  cluster-domain ConfigMap -> ${NEW_DOMAIN}"
}

smoke_test() {
  local code providers
  for url in \
    "https://aiwbui.${NEW_DOMAIN}/" \
    "https://kc.${NEW_DOMAIN}/" \
    "https://airmui.${NEW_DOMAIN}/"; do
    code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || echo "000")
    echo "  ${url} -> HTTP ${code}"
  done
  providers=$(curl -sk --max-time 10 "https://aiwbui.${NEW_DOMAIN}/api/auth/providers" 2>/dev/null || true)
  if echo "${providers}" | grep -q keycloak; then
    echo "  NextAuth Keycloak provider: OK"
  else
    echo "  WARN: NextAuth providers unhealthy"
    return 1
  fi
}

echo "[1/7] cluster-domain ConfigMap"
update_cluster_domain_cm

echo "[2/7] cluster-tls wildcard cert"
TLS_DIR=$(generate_cluster_tls "${NEW_DOMAIN}" "${NODE_IP}")
apply_cluster_tls_secret envoy-gateway-system "${TLS_DIR}/tls.crt" "${TLS_DIR}/tls.key"
# argocd ExternalSecret reads from envoy-gateway-system via ClusterSecretStore
kubectl annotate externalsecret cluster-tls -n argocd \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || true
rm -rf "${TLS_DIR}"

echo "[3/7] /etc/hosts (browser DNS for *.${NEW_DOMAIN})"
update_cluster_hosts

echo "[4/7] MetalLB + Gateway LB IP"
update_metallb_pool
update_gateway_lb

echo "[5/7] ArgoCD application domain parameters + Gateway hostnames"
# Gateway API requires lowercase DNS labels in listener hostnames.
NEW_DOMAIN="$(echo "${NEW_DOMAIN}" | tr '[:upper:]' '[:lower:]')"
ARGO_APPS=(
  "envoy-gateway-config:domain:${NEW_DOMAIN}"
  "keycloak:domain:${NEW_DOMAIN}"
  "minio-tenant-config:domain:${NEW_DOMAIN}"
  "openbao-config:domain:${NEW_DOMAIN}"
  "aiwb:appDomain:${NEW_DOMAIN}"
  "airm:airm-api.airm.appDomain:${NEW_DOMAIN}"
  "argocd:global.domain:${NEW_DOMAIN}"
)
for entry in "${ARGO_APPS[@]}"; do
  IFS=: read -r app param value <<<"${entry}"
  patch_argocd_app_param "${app}" "${param}" "${value}"
done

if kubectl get gateway https -n envoy-gateway-system &>/dev/null; then
  kubectl patch gateway https -n envoy-gateway-system --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/listeners/0/hostname\",\"value\":\"*.${NEW_DOMAIN}\"},
    {\"op\":\"replace\",\"path\":\"/spec/listeners/1/hostname\",\"value\":\"k8s.${NEW_DOMAIN}\"}
  ]" 2>/dev/null || true
  echo "  Gateway listeners -> *.${NEW_DOMAIN}"
fi

echo "[6/7] ArgoCD sync + HTTPRoute parentRefs"
sync_argocd_apps envoy-gateway-config keycloak aiwb airm minio-tenant-config openbao-config

# Chart defaults still point at deprecated kgateway-system on some installs.
for route in aiwb-ui-route aiwb-api-route; do
  kubectl get httproute "${route}" -n aiwb &>/dev/null && \
    kubectl patch httproute "${route}" -n aiwb --type=json \
      -p='[{"op":"replace","path":"/spec/parentRefs/0/namespace","value":"envoy-gateway-system"}]' 2>/dev/null || true
done

echo "  waiting for rollouts..."
for deploy in keycloak aiwb-ui aiwb-api airm-ui airm-api; do
  ns=""
  case "${deploy}" in
    keycloak) ns=keycloak ;;
    aiwb-*) ns=aiwb ;;
    airm-*) ns=airm ;;
  esac
  kubectl rollout status "deployment/${deploy}" -n "${ns}" --timeout=300s 2>/dev/null || true
done

# aiwb-chart 2.0.0-rc.1 can render mixed-case hostnames (hostname -s) while Keycloak
# realm redirect URIs use lowercase appDomain — breaks OAuth redirect_uri validation.
fix_aiwb_auth_urls() {
  if ! kubectl get deployment aiwb-ui -n aiwb &>/dev/null; then
    return 0
  fi
  local d="${NEW_DOMAIN}"
  kubectl set env deployment/aiwb-ui -n aiwb \
    NEXTAUTH_URL="https://aiwbui.${d}" \
    KEYCLOAK_ISSUER="https://kc.${d}/realms/airm" \
    AIRM_APP_URL="https://airmui.${d}" 2>/dev/null || true
  kubectl rollout status deployment/aiwb-ui -n aiwb --timeout=180s 2>/dev/null || true
  echo "  aiwb-ui auth URLs -> lowercase *.${d}"
}
fix_aiwb_auth_urls

bash "$SCRIPT_DIR/fix-keycloak-realm-domain.sh" "${NEW_DOMAIN}" || true

echo "[7/7] smoke test"
sleep 5
smoke_test

echo ""
echo "Migration complete."
echo "  AI Workbench : https://aiwbui.${NEW_DOMAIN}/"
echo "  Sign in      : devuser@${NEW_DOMAIN}"
echo "  AIM catalog  : https://aiwbui.${NEW_DOMAIN}/demo/models/aim-catalog"
echo ""
echo "If DHCP changes the node IP again, run: sudo bash scripts/fix-node-ip.sh"
disk_report "migrate-domain-hostname-done"
