#!/usr/bin/env bash
# Ensure Phi-4 14B appears in AI Workbench Chat model selector.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
MODEL="microsoft-phi-4-14b"

echo "=== ensure-phi-4-14b-chattable (${MODEL}) ==="

if ! kubectl get aimclustermodel "$MODEL" &>/dev/null; then
  echo "ERROR: AIMClusterModel ${MODEL} not found — run CATALOG_ONLY=1 scripts/13-phi-4-14b.sh"
  exit 1
fi

extract="$(kubectl get aimclustermodel "$MODEL" -o jsonpath='{.spec.discovery.extractMetadata}' 2>/dev/null || true)"
tags="$(kubectl get aimclustermodel "$MODEL" -o jsonpath='{.status.imageMetadata.model.tags}' 2>/dev/null || true)"

if [[ "$extract" == "false" ]] || [[ "$tags" != *"chat"* ]]; then
  echo "Patching ${MODEL}: allow spec imageMetadata → status..."
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
exit 1
