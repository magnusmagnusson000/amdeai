#!/usr/bin/env bash
# Mount qwen3-6-27b-r9700-gfx1151-latency profile ConfigMap into Workbench AIM predictors.
# Fixes: ProfileNotFound when AIM operator omits the profile volume on InferenceService.
#
# Mount the ConfigMap at /workspace/aim-runtime/profiles/qwen/qwen3-6-27b/
# (nested path — flat mount at profiles/ causes ProfileNotFound on aim-runtime 0.11).
#
# Usage:
#   bash scripts/ensure-qwen-profile-mount.sh [namespace]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EAI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${1:-demo}"
CM="qwen3-6-27b-r9700-gfx1151-latency-profile"
MOUNT_PATH="/workspace/aim-runtime/profiles/qwen/qwen3-6-27b"
VOL="qwen3-6-27b-profile"

echo "=== ensure-qwen-profile-mount (namespace=${NS}) ==="
kubectl apply -f "${EAI_ROOT}/manifests/aim/qwen3-6-27b/qwen3-6-27b-r9700-gfx1151-latency-profile-configmap.yaml"
if [[ "$NS" != "demo" ]]; then
  kubectl get configmap "$CM" -n demo -o yaml \
    | sed "s/namespace: demo/namespace: ${NS}/" \
    | kubectl apply -f -
fi

for ISVC in $(kubectl get inferenceservice -n "$NS" -o name 2>/dev/null | grep -E 'wb-aim|qwen3-6-27b' || true); do
  name="${ISVC#*/}"
  echo "Patching ${NS}/${name}..."
  kubectl get inferenceservice "$name" -n "$NS" -o json | python3 -c "
import json,sys
isvc=json.load(sys.stdin)
pred=isvc['spec']['predictor']
pred['volumes']=[v for v in pred.get('volumes',[]) if v.get('name')!='${VOL}']
pred['volumes'].append({'name':'${VOL}','configMap':{'name':'${CM}'}})
c=pred['containers'][0]
c['volumeMounts']=[m for m in c.get('volumeMounts',[]) if m.get('name')!='${VOL}']
c['volumeMounts'].append({'name':'${VOL}','mountPath':'${MOUNT_PATH}','readOnly':True})
print(json.dumps({'spec':{'predictor':pred}}))
" | kubectl patch inferenceservice "$name" -n "$NS" --type=merge -p "$(cat)"
  kubectl delete pod -n "$NS" -l "serving.kserve.io/inferenceservice=${name}" --force --grace-period=0 2>/dev/null || true
done

echo "Profile mount applied. Predictor pods restarting."
