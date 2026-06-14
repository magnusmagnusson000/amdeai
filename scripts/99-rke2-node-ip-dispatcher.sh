#!/bin/bash
# Automatically update RKE2 node-ip and etcd peer URL when the DHCP lease changes.
# Triggered by NetworkManager on interface events.

IFACE="$1"
EVENT="$2"
RKE2_CONFIG=/etc/rancher/rke2/config.yaml
LOGFILE=/var/log/rke2-node-ip-update.log

# Only act on the physical WiFi/Ethernet interface going up with a new address
[[ "$EVENT" != "up" && "$EVENT" != "dhcp4-change" ]] && exit 0
[[ "$IFACE" == lo* || "$IFACE" == veth* || "$IFACE" == cni* || "$IFACE" == cil* ]] && exit 0
[[ "$IFACE" == docker* || "$IFACE" == br-* || "$IFACE" == tunl* ]] && exit 0

NEW_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
[[ -z "$NEW_IP" ]] && exit 0

OLD_IP=$(grep '^node-ip:' "$RKE2_CONFIG" 2>/dev/null | awk '{print $2}')
[[ "$NEW_IP" == "$OLD_IP" ]] && exit 0

echo "$(date): $IFACE changed: $OLD_IP -> $NEW_IP" >> "$LOGFILE"

# 1. Update node-ip in RKE2 config
sed -i "s|^node-ip:.*|node-ip: ${NEW_IP}|" "$RKE2_CONFIG"

# 2. Update tls-san entry for the old IP
sed -i "s|\"${OLD_IP}\"|\"${NEW_IP}\"|g" "$RKE2_CONFIG"

# 3. Update etcd member peer URL while etcd is running
ETCDCTL=$(find /var/lib/rancher/rke2/agent/containerd -name etcdctl -type f 2>/dev/null | head -1)
CERT_DIR=/var/lib/rancher/rke2/server/tls/etcd

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
            --peer-urls "https://${NEW_IP}:2380" >> "$LOGFILE" 2>&1
        echo "$(date): etcd member peer URL updated to ${NEW_IP}:2380" >> "$LOGFILE"
    fi
fi

# 4. Restart RKE2 to apply new node-ip and regenerate TLS certs
echo "$(date): Restarting rke2-server..." >> "$LOGFILE"
systemctl restart rke2-server >> "$LOGFILE" 2>&1 &

# 5. Update kubeconfig server address
KUBECONFIG=/root/.kube/config
[[ -f "$KUBECONFIG" ]] && sed -i "s|https://${OLD_IP}:6443|https://$(hostname -s):6443|g" "$KUBECONFIG"
# Also fix the user's kubeconfig
for f in /home/*/.kube/config; do
    [[ -f "$f" ]] && sed -i "s|https://${OLD_IP}:6443|https://$(hostname -s):6443|g" "$f"
done

echo "$(date): Done. RKE2 restarting in background." >> "$LOGFILE"
