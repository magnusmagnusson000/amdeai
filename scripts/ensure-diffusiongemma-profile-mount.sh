#!/usr/bin/env bash
# Mount diffusiongemma-26b profile ConfigMap into AIM predictors.
#
# Usage:
#   bash scripts/ensure-diffusiongemma-profile-mount.sh [namespace]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EAI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${1:-demo}"
CM="diffusiongemma-26b-r9700-gfx1151-latency-profile"
MOUNT_PATH="/workspace/aim-runtime/profiles/google/diffusiongemma-26b"
VOL="diffusiongemma-26b-profile"

echo "=== ensure-diffusiongemma-profile-mount (namespace=${NS}) ==="
kubectl apply -f "${EAI_ROOT}/manifests/aim/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency-profile-configmap.yaml"
if [[ "$NS" != "demo" ]]; then
  kubectl get configmap "$CM" -n demo -o yaml \
    | sed "s/namespace: demo/namespace: ${NS}/" \
    | kubectl apply -f -
fi

for ISVC in $(kubectl get inferenceservice -n "$NS" -o name 2>/dev/null | grep -iE 'wb-aim|diffusiongemma' || true); do
  name="${ISVC#*/}"
  # Skip paused MoE predictors (no running pod) — only patch ISVCs for DiffusionGemma AIMServices
  matched=0
  for svc in $(kubectl get aimservice -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.model.name}{"\n"}{end}' 2>/dev/null); do
    svc_name="${svc%% *}"
    model="${svc#* }"
    if [[ "$model" == "google-diffusiongemma-26b" ]] && [[ "$name" == *"$svc_name"* ]]; then
      matched=1
      break
    fi
  done
  if [[ "$matched" == "0" ]] && ! echo "$name" | grep -qi diffusiongemma; then
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
env=c.setdefault('env',[])
strip_names={'VLLM_USE_V1','HSA_XNACK','PYTORCH_HIP_ALLOC_CONF'}
env=[e for e in env if e.get('name') not in strip_names]
env.extend([
  {'name':'VLLM_USE_V1','value':'0'},
  {'name':'HSA_XNACK','value':'0'},
  {'name':'PYTORCH_HIP_ALLOC_CONF','value':'expandable_segments:False'},
])
c['env']=env
print(json.dumps({'spec':{'predictor':pred}}))
" | kubectl patch inferenceservice "$name" -n "$NS" --type=merge -p "$(cat)"
  kubectl delete pod -n "$NS" -l "serving.kserve.io/inferenceservice=${name}" --force --grace-period=0 2>/dev/null || true
done

echo "DiffusionGemma profile mount applied. Predictor pods restarting."
