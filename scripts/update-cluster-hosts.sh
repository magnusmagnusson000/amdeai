#!/usr/bin/env bash
# Keep /etc/hosts in sync so *.$(hostname -s) resolve to the current node IP.
# Called by migrate-domain-hostname.sh and fix-node-ip.sh after DHCP changes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

NODE_IP="${1:-$(my_ip)}"
DOMAIN="${2:-$(domain)}"
HOSTS_MARKER="# amdeai-cluster-ui-hosts"

hosts_line="${NODE_IP} $(ui_hostnames "${DOMAIN}")"
tmp=$(mktemp)
if [[ -f /etc/hosts ]]; then
  grep -v "${HOSTS_MARKER}" /etc/hosts \
    | grep -vE "(aiwbui|aiwbapi|airmui|airmapi|kc|keycloak|argocd|gitea|openbao|k8s)\.${DOMAIN//./\\.}" \
    >"${tmp}" || true
else
  : >"${tmp}"
fi
echo "${hosts_line} ${HOSTS_MARKER}" >>"${tmp}"
sudo cp "${tmp}" /etc/hosts
rm -f "${tmp}"
echo "Updated /etc/hosts: *.${DOMAIN} -> ${NODE_IP}"
