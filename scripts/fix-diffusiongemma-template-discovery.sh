#!/usr/bin/env bash
# Work around AIM operator discovery log race on gfx1151 Bloom.
#
# Discovery jobs finish in ~10s; the operator often misses pod logs and the
# template stays Progressing. This script writes Ready status from image
# dry-run output via the status subresource (merge patch fails on the nested
# "status" field name).
#
# Usage:
#   bash scripts/fix-diffusiongemma-template-discovery.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

TEMPLATE="diffusiongemma-26b-r9700-gfx1151-latency"
REFERENCE_TEMPLATE="qwen3-6-35b-moe-r9700-gfx1151-latency"
IMAGE="${AIM_IMAGE:-$(registry_host)/aim-gfx1151-diffusiongemma-26b:0.11-therock}"
OPERATOR_DEPLOY="${AIM_OPERATOR_DEPLOY:-aim-engine-controller-manager}"
OPERATOR_NS="${AIM_OPERATOR_NS:-aim-system}"

echo "=== fix-diffusiongemma-template-discovery ==="

STATUS=$(kubectl get aimclusterservicetemplate "$TEMPLATE" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
if [[ "$STATUS" == "Ready" ]] && kubectl get aimclusterservicetemplate "$TEMPLATE" \
  -o jsonpath='{.status.profile.metadata.aimId}' 2>/dev/null | grep -q diffusiongemma; then
  echo "Template already Ready with profile."
  exit 0
fi

# Prefer a fresh discovery job + reconcile hammer before manual status backfill.
JOB=$(kubectl get job -n "$OPERATOR_NS" -o name 2>/dev/null | grep "discover-${TEMPLATE}" | head -1 || true)
if [[ -z "$JOB" ]]; then
  kubectl delete lease aim-discovery-lock -n "$OPERATOR_NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl annotate aimclusterservicetemplate "$TEMPLATE" \
    aim.eai.amd.com/reconcile="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    JOB=$(kubectl get job -n "$OPERATOR_NS" -o name 2>/dev/null | grep "discover-${TEMPLATE}" | head -1 || true)
    [[ -n "$JOB" ]] && break
    sleep 2
  done
fi

if [[ -n "$JOB" ]]; then
  JOB_NAME="${JOB#job.batch/}"
  echo "Waiting for discovery job ${JOB_NAME}..."
  kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "$OPERATOR_NS" --timeout=300s 2>/dev/null || true
  for i in $(seq 1 30); do
    kubectl annotate aimclusterservicetemplate "$TEMPLATE" \
      aim.eai.amd.com/reconcile="$(date +%s)-${i}" --overwrite >/dev/null 2>&1 || true
    STATUS=$(kubectl get aimclusterservicetemplate "$TEMPLATE" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    [[ "$STATUS" == "Ready" ]] && kubectl get aimclusterservicetemplate "$TEMPLATE" \
      -o jsonpath='{.status.profile.metadata.aimId}' 2>/dev/null | grep -q diffusiongemma && {
      echo "Template became Ready after discovery."
      exit 0
    }
    sleep 1
  done
fi

echo "Manual status backfill from ${IMAGE} dry-run..."
python3 - "$TEMPLATE" "$REFERENCE_TEMPLATE" "$IMAGE" "$OPERATOR_DEPLOY" "$OPERATOR_NS" <<'PY'
import copy
import json
import subprocess
import sys
import time

template, reference, image, operator_deploy, operator_ns = sys.argv[1:6]

dry = subprocess.check_output(
    [
        "docker", "run", "--rm",
        "-e", f"AIM_PROFILE_ID={template}",
        image, "dry-run", "--format=json",
    ],
    stderr=subprocess.DEVNULL,
    text=True,
)
payload = json.loads(dry)[0]
prof = payload["profile"]
models = payload.get("models", [])
size = str(int(models[0]["size_gb"] * 1024**3)) if models else str(int(48.13 * 1024**3))
model_id = prof["model_id"]

subprocess.run(
    ["kubectl", "scale", f"deploy/{operator_deploy}", "-n", operator_ns, "--replicas=0"],
    check=True,
)
for _ in range(30):
    phases = subprocess.run(
        [
            "kubectl", "get", "pods", "-n", operator_ns,
            "-l", "control-plane=controller-manager",
            "-o", "jsonpath={.items[*].status.phase}",
        ],
        capture_output=True,
        text=True,
    ).stdout.strip()
    if not phases:
        break
    time.sleep(2)

ref = json.loads(
    subprocess.check_output(
        ["kubectl", "get", "aimclusterservicetemplate", reference, "-o", "json"],
        text=True,
    )
)
cur = json.loads(
    subprocess.check_output(
        ["kubectl", "get", "aimclusterservicetemplate", template, "-o", "json"],
        text=True,
    )
)

status = copy.deepcopy(ref["status"])
status["discoveryJob"] = cur["status"].get("discoveryJob", {})
status["version"] = cur["status"].get("version", "0.11-therock")
status["resolvedModel"] = {"name": "google-diffusiongemma-26b"}
status["status"] = "Ready"
status["hardwareSummary"] = "1 x R9700"
status["modelSources"] = [
    {"modelId": model_id, "size": size, "sourceUri": f"hf://{model_id}"},
]
status["profile"] = {
    "engine_args": prof["engine_args"],
    "env_vars": prof.get("env_vars", {}),
    "metadata": {
        "aimId": prof["aim_id"],
        "engine": prof["metadata"]["engine"],
        "gpu": prof["metadata"]["gpu"],
        "gpuCount": prof["metadata"]["gpu_count"],
        "metric": prof["metadata"]["metric"],
        "modelId": model_id,
        "precision": prof["metadata"]["precision"],
        "type": "unoptimized",
    },
}
status["discovery"] = {
    "identityCheckHash": "v1:manual-diffusiongemma",
    "lastIdentityCheckTime": subprocess.check_output(
        ["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], text=True
    ).strip(),
}
now = status["discovery"]["lastIdentityCheckTime"]
for cond in status.get("conditions", []):
    if cond["type"] in ("DiscoveryJobReady", "Discovered", "Ready"):
        cond.update({"status": "True", "lastTransitionTime": now})
        if cond["type"] == "DiscoveryJobReady":
            cond.update({"reason": "Ready", "message": ""})
        elif cond["type"] == "Discovered":
            cond.update({"reason": "Discovered", "message": "Discovery complete"})
        elif cond["type"] == "Ready":
            cond.update({"reason": "AllComponentsReady", "message": "All components are ready"})

body = {
    "apiVersion": cur["apiVersion"],
    "kind": cur["kind"],
    "metadata": {
        "name": cur["metadata"]["name"],
        "resourceVersion": cur["metadata"]["resourceVersion"],
    },
    "status": status,
}
put = subprocess.run(
    [
        "kubectl", "replace", "--raw",
        f"/apis/aim.eai.amd.com/v1alpha1/aimclusterservicetemplates/{template}/status",
        "-f", "-",
    ],
    input=json.dumps(body),
    capture_output=True,
    text=True,
)
if put.returncode != 0:
    subprocess.run(
        ["kubectl", "scale", f"deploy/{operator_deploy}", "-n", operator_ns, "--replicas=1"],
        check=False,
    )
    sys.stderr.write(put.stderr)
    sys.exit(put.returncode)

subprocess.run(
    ["kubectl", "scale", f"deploy/{operator_deploy}", "-n", operator_ns, "--replicas=1"],
    check=True,
)
print("Template status patched to Ready.")
PY

kubectl get aimclusterservicetemplate "$TEMPLATE" -o jsonpath='{.status.status}{"\n"}'
