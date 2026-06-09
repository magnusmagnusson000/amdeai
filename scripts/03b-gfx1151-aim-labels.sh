#!/usr/bin/env bash
# Apply AIM Engine accelerator labels for Strix Halo (gfx1151).
#
# Bloom labels the node as MI300X for Cluster Forge compatibility, but AIM
# template selection for Radeon uses feature.node.kubernetes.io/aim-accelerator.*
# labels written by the AcceleratorDetector — which only recognises Instinct
# MI-series GPUs today. Strix Halo (Radeon 8060S, PCI 0x1586) maps to R9700
# in AIM Engine v0.2.4+ (Radeon AI Pro class).
#
# v1alpha2 AIMClusterProfile scheduling uses aim-accelerator.{model}: Exists,
# not PCI device-id, so this label is sufficient for Gemma 4 AIM services.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

NODE="${AIM_NODE:-$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')}"

echo "=== 03b-gfx1151-aim-labels (node=${NODE}) ==="

kubectl label node "${NODE}" \
  feature.node.kubernetes.io/aim-accelerator.R9700=1 \
  amd.com/gpu.device-id=7551 \
  amdeai.com/gpu.device-id.actual=1586 \
  amd.com/gpu.vram=128G \
  kaiwo/gpu-model=gfx1151 \
  kaiwo/nodepool=amd-gfx1151-1gpu \
  --overwrite

# Persist through NFD local feature source (same mechanism as AcceleratorDetector).
NFD_DIR="/etc/kubernetes/node-feature-discovery/features.d"
if [[ -d "$NFD_DIR" ]] || sudo -n test -d "$NFD_DIR" 2>/dev/null; then
  FEATURE_FILE="${NFD_DIR}/aim-accelerator-gfx1151"
  TMP=$(mktemp)
  cat > "$TMP" << 'EOF'
# AIM template matching maps PCI device-id labels via KnownAmdDevices; gfx1151
# (1586) is not listed yet, so we advertise 7551 (R9700) for catalog templates.
# Actual hardware remains gfx1151 — see amdeai.com/gpu.device-id.actual=1586.
feature.node.kubernetes.io/aim-accelerator.R9700=1
amd.com/gpu.device-id=7551
amdeai.com/gpu.device-id.actual=1586
EOF
  if [[ -w "$NFD_DIR" ]]; then
    cp "$TMP" "$FEATURE_FILE"
  else
    sudo cp "$TMP" "$FEATURE_FILE"
  fi
  rm -f "$TMP"
  echo "NFD feature file: ${FEATURE_FILE}"
else
  echo "WARN: ${NFD_DIR} not found — kubectl labels applied but may not survive NFD resync"
fi

echo "AIM accelerator labels on ${NODE}:"
kubectl get node "${NODE}" --show-labels | tr ',' '\n' | grep -E 'aim-accelerator|gpu\.device-id|gpu\.vram|kaiwo/gpu-model' || true

echo "Call flow: $EAI_ROOT/docs/call-flows/03b-gfx1151-aim-labels.md"
