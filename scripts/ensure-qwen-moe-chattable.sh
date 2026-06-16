#!/usr/bin/env bash
# Ensure Qwen3.6-35B-MoE appears in AI Workbench Chat model selector.
#
# Workbench /api/namespaces/<ns>/chattable requires the AIMClusterModel to expose
# a "chat" tag in status.imageMetadata. With spec.discovery.extractMetadata=false
# the AIM operator skips copying spec.imageMetadata into status — remove that flag
# so the chat tag is published.
#
# Usage:
#   bash scripts/ensure-qwen-moe-chattable.sh
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
MODEL="qwen-qwen3-6-35b-moe"

echo "=== ensure-qwen-moe-chattable (${MODEL}) ==="

if ! kubectl get aimclustermodel "$MODEL" &>/dev/null; then
  echo "ERROR: AIMClusterModel ${MODEL} not found — run CATALOG_ONLY=1 bash scripts/11-qwen3-6-35b-moe.sh"
  exit 1
fi

extract="$(kubectl get aimclustermodel "$MODEL" -o jsonpath='{.spec.discovery.extractMetadata}' 2>/dev/null || true)"
tags="$(kubectl get aimclustermodel "$MODEL" -o jsonpath='{.status.imageMetadata.model.tags}' 2>/dev/null || true)"

if [[ "$extract" == "false" ]] || [[ "$tags" != *"chat"* ]]; then
  echo "Patching ${MODEL}: allow spec imageMetadata → status (remove extractMetadata=false)..."
  kubectl patch aimclustermodel "$MODEL" --type=json \
    -p='[{"op":"remove","path":"/spec/discovery/extractMetadata"}]' 2>/dev/null \
    || kubectl patch aimclustermodel "$MODEL" --type=merge \
         -p='{"spec":{"discovery":{"extractMetadata":true}}}'
fi

deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  tags="$(kubectl get aimclustermodel "$MODEL" -o jsonpath='{.status.imageMetadata.model.tags}' 2>/dev/null || true)"
  if [[ "$tags" == *"chat"* ]]; then
    echo "OK: status.imageMetadata.model.tags includes chat (${tags})"
    exit 0
  fi
  sleep 2
done

echo "WARN: chat tag not yet in status.imageMetadata after 60s (tags=${tags:-empty})"
kubectl get aimclustermodel "$MODEL" -o yaml | grep -A5 'imageMetadata' || true
exit 1
