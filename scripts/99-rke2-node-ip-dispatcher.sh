#!/bin/bash
# Automatically update RKE2 node-ip and etcd peer URL when the DHCP lease changes.
# Triggered by NetworkManager on interface events.
#
# The workshop address is pinned to 192.168.32.103 (Wi-Fi reservation and volt0).
# Never follow virbr0/libvirt or any other address: airplane mode and boot races
# used to rewrite node-ip to 192.168.122.1 and restart rke2 mid-demo.

IFACE="$1"
EVENT="$2"
RKE2_CONFIG=/etc/rancher/rke2/config.yaml
LOGFILE=/var/log/rke2-node-ip-update.log
WORKSHOP_IP=192.168.32.103

[[ "$EVENT" != "up" && "$EVENT" != "dhcp4-change" ]] && exit 0
[[ "$IFACE" == lo* || "$IFACE" == veth* || "$IFACE" == cni* || "$IFACE" == cil* ]] && exit 0
[[ "$IFACE" == docker* || "$IFACE" == br-* || "$IFACE" == tunl* ]] && exit 0
[[ "$IFACE" == virbr* || "$IFACE" == vnet* || "$IFACE" == tap* ]] && exit 0

NEW_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk "/inet /{print \$2}" | cut -d/ -f1 | head -1)
[[ -z "$NEW_IP" ]] && exit 0

# Only the pinned workshop address may become node-ip.
[[ "$NEW_IP" == "$WORKSHOP_IP" ]] || exit 0

OLD_IP=$(grep "^node-ip:" "$RKE2_CONFIG" 2>/dev/null | awk "{print \$2}")
[[ "$NEW_IP" == "$OLD_IP" ]] && exit 0

echo "$(date): $IFACE changed: $OLD_IP -> $NEW_IP" >> "$LOGFILE"

sed -i "s|^node-ip:.*|node-ip: ${NEW_IP}|" "$RKE2_CONFIG"
sed -i "s|\"${OLD_IP}\"|\"${NEW_IP}\"|g" "$RKE2_CONFIG"

ETCDCTL=$(find /var/lib/rancher/rke2/agent/containerd -name etcdctl -type f 2>/dev/null | head -1)
CERT_DIR=/var/lib/rancher/rke2/server/tls/etcd

if [[ -n "$ETCDCTL" && -f "$CERT_DIR/client.crt" ]]; then
    MEMBER_ID=$("$ETCDCTL" \
        --endpoints "https://127.0.0.1:2379" \
        --cacert "$CERT_DIR/server-ca.crt" \
        --cert "$CERT_DIR/client.crt" \
        --key "$CERT_DIR/client.key" \
        member list 2>/dev/null | awk -F, "{print \$1}")

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

echo "$(date): Restarting rke2-server..." >> "$LOGFILE"
systemctl restart rke2-server >> "$LOGFILE" 2>&1 &

KUBECONFIG=/root/.kube/config
[[ -f "$KUBECONFIG" ]] && sed -i "s|https://${OLD_IP}:6443|https://$(hostname -s):6443|g" "$KUBECONFIG"
for f in /home/*/.kube/config; do
    [[ -f "$f" ]] && sed -i "s|https://${OLD_IP}:6443|https://$(hostname -s):6443|g" "$f"
done

echo "$(date): Done. RKE2 restarting in background." >> "$LOGFILE"
