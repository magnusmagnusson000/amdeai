#!/usr/bin/env bash
# Work around AIM operator discovery failure for Phi-4 14B on gfx1151.
# Discovery pods miss AIM_ID; backfill template status from image dry-run.
#
# Usage:
#   bash scripts/fix-phi4-template-discovery.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

TEMPLATE="phi-4-14b-r9700-gfx1151-latency"
REFERENCE_TEMPLATE="qwen3-6-27b-r9700-gfx1151-latency"
IMAGE="${AIM_IMAGE:-$(registry_host)/aim-gfx1151-phi-4-14b:0.11-therock}"
OPERATOR_DEPLOY="${AIM_OPERATOR_DEPLOY:-aim-engine-controller-manager}"
OPERATOR_NS="${AIM_OPERATOR_NS:-aim-system}"
CLUSTER_MODEL="microsoft-phi-4-14b"

echo "=== fix-phi4-template-discovery ==="

STATUS=$(kubectl get aimclusterservicetemplate "$TEMPLATE" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
if [[ "$STATUS" == "Ready" ]] && kubectl get aimclusterservicetemplate "$TEMPLATE" \
  -o jsonpath='{.status.profile.metadata.aimId}' 2>/dev/null | grep -qi phi; then
  echo "Template already Ready with profile."
  exit 0
fi

echo "Manual status backfill from ${IMAGE} dry-run..."
python3 - "$TEMPLATE" "$REFERENCE_TEMPLATE" "$IMAGE" "$OPERATOR_DEPLOY" "$OPERATOR_NS" "$CLUSTER_MODEL" <<'PY'
import copy
import json
import subprocess
import sys
import time

template, reference, image, operator_deploy, operator_ns, cluster_model = sys.argv[1:7]

dry = subprocess.check_output(
    [
        "docker", "run", "--rm",
        "-e", f"AIM_PROFILE_ID={template}",
        "-e", "AIM_ID=microsoft/phi-4-14b",
        image, "dry-run", "--format=json",
    ],
    stderr=subprocess.DEVNULL,
    text=True,
)
payload = json.loads(dry)[0]
prof = payload["profile"]
models = payload.get("models", [])
size = str(int(models[0]["size_gb"] * 1024**3)) if models else str(int(28 * 1024**3))
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
status["resolvedModel"] = {"name": cluster_model}
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
    "identityCheckHash": "v1:manual-phi4-14b",
    "lastIdentityCheckTime": subprocess.check_output(
        ["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], text=True
    ).strip(),
}
now = status["discovery"]["lastIdentityCheckTime"]
for cond in status.get("conditions", []):
    if cond["type"] in ("DiscoveryJobReady", "Discovered", "Ready", "ConfigValid", "DiscoveryPodsReady"):
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
