#!/usr/bin/env bash
# Update live Keycloak airm realm after hostname domain migration.
# Realm import only runs on first boot — redirect URIs stay on the old <ip>.nip.io until patched.
#
# Usage: bash scripts/fix-keycloak-realm-domain.sh [domain]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
DOMAIN="${1:-$(domain)}"
OLD_DOMAIN="${OLD_DOMAIN:-192.168.32.13.nip.io}"
FRONTEND_CLIENT_ID="354a0fa1-35ac-4a6d-9c4d-d661129c2cd0"

echo "=== fix-keycloak-realm-domain (${OLD_DOMAIN} -> ${DOMAIN}) ==="

ADMIN_PW=$(kubectl get secret keycloak-credentials -n keycloak \
  -o jsonpath='{.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}' | base64 -d)

kubectl exec -n keycloak deploy/keycloak -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://127.0.0.1:8080 --realm master --user silogen-admin --password "${ADMIN_PW}" >/dev/null

INTERNAL_ID=$(kubectl exec -n keycloak deploy/keycloak -- /opt/keycloak/bin/kcadm.sh get clients \
  -r airm -q "clientId=${FRONTEND_CLIENT_ID}" --fields id 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'])")

echo "Patching frontend client ${FRONTEND_CLIENT_ID} (${INTERNAL_ID})..."
kubectl exec -n keycloak deploy/keycloak -- /opt/keycloak/bin/kcadm.sh update "clients/${INTERNAL_ID}" -r airm \
  -s 'redirectUris=["https://airmapi.'"${DOMAIN}"'/*","https://airmui.'"${DOMAIN}"'/*","https://aiwbui.'"${DOMAIN}"'/*","https://aiwbapi.'"${DOMAIN}"'/*","https://'"${DOMAIN}"'/*"]' \
  -s 'webOrigins=["*"]' >/dev/null

# DevUser username/email must match login form (devuser@<domain>)
DEVUSER_ID=$(kubectl exec -n keycloak deploy/keycloak -- /opt/keycloak/bin/kcadm.sh get users -r airm \
  -q "username=devuser@${OLD_DOMAIN}" --fields id 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || true)
if [[ -z "${DEVUSER_ID}" ]]; then
  DEVUSER_ID=$(kubectl exec -n keycloak deploy/keycloak -- /opt/keycloak/bin/kcadm.sh get users -r airm \
    -q "username=devuser@${DOMAIN}" --fields id 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || true)
fi
if [[ -n "${DEVUSER_ID}" ]]; then
  kubectl exec -n keycloak deploy/keycloak -- /opt/keycloak/bin/kcadm.sh update "users/${DEVUSER_ID}" -r airm \
    -s "username=devuser@${DOMAIN}" -s "email=devuser@${DOMAIN}" >/dev/null
  echo "DevUser -> devuser@${DOMAIN}"
fi

echo "Keycloak realm updated."
