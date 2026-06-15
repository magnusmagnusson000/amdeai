#!/usr/bin/env bash
# Patch AIM HTTPRoutes that reference kgateway-system to use envoy-gateway-system.
# Required on gfx1151 Bloom: AIMService stays Starting until HTTPRoute is Accepted.
#
# Usage:
#   bash scripts/fix-aim-httproute-gateway.sh [namespace...]
#   bash scripts/fix-aim-httproute-gateway.sh demo default
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

TARGET_NS="${GATEWAY_NAMESPACE:-envoy-gateway-system}"
NAMESPACES=("$@")
if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
  NAMESPACES=(demo default)
fi

echo "=== fix-aim-httproute-gateway (parent -> ${TARGET_NS}/https) ==="

if ! kubectl get gateway https -n "$TARGET_NS" &>/dev/null; then
  echo "ERROR: Gateway https not found in ${TARGET_NS}"
  exit 1
fi

fixed=0
for NS in "${NAMESPACES[@]}"; do
  for route in $(kubectl get httproute -n "$NS" -o name 2>/dev/null || true); do
    parent_ns=$(kubectl get "$route" -n "$NS" -o jsonpath='{.spec.parentRefs[0].namespace}' 2>/dev/null || echo "")
    if [[ "$parent_ns" == "kgateway-system" || -z "$parent_ns" ]]; then
      name="${route#*/}"
      echo "Patching ${NS}/${name} parentRefs.namespace -> ${TARGET_NS}"
      kubectl patch httproute "$name" -n "$NS" --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/parentRefs/0/namespace\",\"value\":\"${TARGET_NS}\"}]"
      fixed=$((fixed + 1))
    fi
  done
done

if [[ $fixed -eq 0 ]]; then
  echo "No HTTPRoutes needed patching."
else
  echo "Patched ${fixed} route(s). Wait ~10s, then:"
  echo "  kubectl describe httproute -n <ns> | grep -A2 Accepted"
  echo "  kubectl get aimservice -n demo"
fi
