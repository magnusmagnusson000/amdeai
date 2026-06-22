#!/usr/bin/env bash
# Mount phi-4-14b profile ConfigMap into Workbench AIM predictors.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EAI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${1:-demo}"
CM="phi-4-14b-r9700-gfx1151-latency-profile"
MOUNT_PATH="/workspace/aim-runtime/profiles/microsoft/phi-4-14b"
VOL="phi-4-14b-profile"

echo "=== ensure-phi-4-14b-profile-mount (namespace=${NS}) ==="
kubectl apply -f "${EAI_ROOT}/manifests/aim/phi-4-14b/phi-4-14b-r9700-gfx1151-latency-profile-configmap.yaml"
if [[ "$NS" != "demo" ]]; then
  kubectl get configmap "$CM" -n demo -o yaml \
    | sed "s/namespace: demo/namespace: ${NS}/" \
    | kubectl apply -f -
fi

for ISVC in $(kubectl get inferenceservice -n "$NS" -o name 2>/dev/null | grep -E 'wb-aim|phi-4-14b' || true); do
  name="${ISVC#*/}"
  model_label="$(kubectl get inferenceservice "$name" -n "$NS" \
    -o jsonpath='{.metadata.labels.aim\.eai\.amd\.com/model}' 2>/dev/null || true)"
  if [[ -n "$model_label" ]] && [[ "$model_label" != "microsoft-phi-4-14b" ]] && ! echo "$name" | grep -qi phi; then
    continue
  fi
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
