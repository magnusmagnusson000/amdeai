#!/bin/bash
# fix-node-ip.sh — Update RKE2 node-ip and etcd peer URL after a DHCP IP change.
#
# Run this manually if the node's IP has changed and the cluster is broken.
# The NetworkManager dispatcher at /etc/NetworkManager/dispatcher.d/99-rke2-node-ip
# does this automatically on DHCP events; this script is a manual fallback.
#
# Usage:
#   sudo ./scripts/fix-node-ip.sh
#   sudo ./scripts/fix-node-ip.sh 192.168.32.102   # explicit new IP

set -euo pipefail

RKE2_CONFIG=/etc/rancher/rke2/config.yaml
CERT_DIR=/var/lib/rancher/rke2/server/tls/etcd
ETCDCTL=$(find /var/lib/rancher/rke2/agent/containerd -name etcdctl -type f 2>/dev/null | head -1)

IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
NEW_IP="${1:-$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)}"
OLD_IP=$(grep '^node-ip:' "$RKE2_CONFIG" 2>/dev/null | awk '{print $2}')

if [[ -z "$NEW_IP" ]]; then
    echo "ERROR: Could not determine current IP. Pass it explicitly: $0 <ip>"
    exit 1
fi

echo "Current node-ip in config : ${OLD_IP:-(not set)}"
echo "New IP detected            : $NEW_IP"
echo "Interface                  : $IFACE"
echo ""

if [[ "$NEW_IP" == "$OLD_IP" ]]; then
    echo "node-ip is already correct. No changes needed."
    exit 0
fi

# 1. Update node-ip in RKE2 config
if grep -q '^node-ip:' "$RKE2_CONFIG"; then
    sed -i "s|^node-ip:.*|node-ip: ${NEW_IP}|" "$RKE2_CONFIG"
else
    echo "node-ip: ${NEW_IP}" >> "$RKE2_CONFIG"
fi
echo "[1/4] Updated node-ip in $RKE2_CONFIG"

# 2. Update tls-san entry for the old IP (if present)
if [[ -n "$OLD_IP" ]]; then
    sed -i "s|\"${OLD_IP}\"|\"${NEW_IP}\"|g" "$RKE2_CONFIG"
fi
echo "[2/4] Updated tls-san in $RKE2_CONFIG"

# 3. Update etcd member peer URL (requires etcd to be running)
if [[ -n "$ETCDCTL" && -f "$CERT_DIR/client.crt" ]]; then
    MEMBER_ID=$("$ETCDCTL" \
        --endpoints "https://127.0.0.1:2379" \
        --cacert "$CERT_DIR/server-ca.crt" \
        --cert "$CERT_DIR/client.crt" \
        --key "$CERT_DIR/client.key" \
        member list 2>/dev/null | awk -F, '{print $1}')

    if [[ -n "$MEMBER_ID" ]]; then
        "$ETCDCTL" \
            --endpoints "https://127.0.0.1:2379" \
            --cacert "$CERT_DIR/server-ca.crt" \
            --cert "$CERT_DIR/client.crt" \
            --key "$CERT_DIR/client.key" \
            member update "$MEMBER_ID" \
            --peer-urls "https://${NEW_IP}:2380"
        echo "[3/4] Updated etcd member peer URL to ${NEW_IP}:2380"
    else
        echo "[3/4] WARN: Could not get etcd member ID (etcd may not be running)"
    fi
else
    echo "[3/4] WARN: etcdctl not found or certs missing — skipping etcd peer update"
fi

# 4. Restart RKE2 (regenerates TLS certs with new node IP)
echo "[4/4] Restarting rke2-server..."
systemctl restart rke2-server

echo ""
echo "Waiting for API server..."
for i in $(seq 1 60); do
    if curl -sk --connect-timeout 2 "https://$(hostname -s):6443/readyz" 2>/dev/null | grep -q ok; then
        echo "API ready after ${i}x3s"
        break
    fi
    sleep 3
    echo -n "."
done
echo ""

# 5. Refresh kubeconfig
HOSTNAME=$(hostname -s)
if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
    cp /etc/rancher/rke2/rke2.yaml /tmp/rke2-new.yaml
    sed -i "s|https://[0-9.]*:6443|https://${HOSTNAME}:6443|g" /tmp/rke2-new.yaml
    for DEST in /root/.kube/config /home/*/.kube/config; do
        [[ -f "$DEST" ]] && cp /tmp/rke2-new.yaml "$DEST" && \
            chown "$(stat -c %U "$DEST"):" "$DEST" && \
            echo "Updated kubeconfig: $DEST"
    done
    rm /tmp/rke2-new.yaml
fi

echo ""
echo "Done. RKE2 node-ip updated: $OLD_IP -> $NEW_IP"
echo "Cluster accessible via: https://${HOSTNAME}:6443"
