#!/usr/bin/env bash
# Shared helpers for post-reboot / post-rke2 stack startup hardening.
# Sourced by ensure-stack-startup.sh and fix-web-uis.sh — do not execute directly.
set -euo pipefail

stack_startup_wait_for_kubectl() {
  local timeout="${1:-300}"
  local elapsed=0
  export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
  echo "Waiting for Kubernetes API (up to ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    if kubectl get nodes &>/dev/null; then
      echo "Kubernetes API ready (${elapsed}s)."
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "ERROR: Kubernetes API not ready after ${timeout}s."
  return 1
}

# Keycloak defaults to a 2Gi cgroup limit on Z13 (cluster-forge ArgoCD helm values).
# JVM JIT during cold start routinely exceeds that and triggers cgroup OOM thrash
# (failcnt in the hundreds of thousands), which can freeze the desktop when amdgpu
# SVM restore work runs under memory pressure.
stack_startup_patch_keycloak_argocd() {
  local limit="${KEYCLOAK_MEMORY_LIMIT:-4Gi}"
  local request="${KEYCLOAK_MEMORY_REQUEST:-2Gi}"
  if ! kubectl get application keycloak -n argocd &>/dev/null; then
    return 1
  fi
  python3 - "$limit" "$request" <<'PY'
import json, re, subprocess, sys

limit, request = sys.argv[1], sys.argv[2]
raw = subprocess.check_output(
    ["kubectl", "get", "application", "keycloak", "-n", "argocd", "-o", "json"],
    text=True,
)
app = json.loads(raw)
values = app.get("spec", {}).get("source", {}).get("helm", {}).get("values", "")
if not values:
    sys.exit(1)

patched = values
patched = re.sub(
    r"(resources:\s+limits:\s+cpu:\s+500m\s+memory:\s+)2Gi",
    rf"\g<1>{limit}",
    patched,
    count=1,
)
patched = re.sub(
    r"(resources:\s+requests:\s+cpu:\s+250m\s+memory:\s+)512Mi",
    rf"\g<1>{request}",
    patched,
    count=1,
)
if patched == values:
    # Already patched or unexpected layout — check if limit is correct
    if f"memory: {limit}" in values:
        print(f"ArgoCD keycloak helm values already use limit={limit}.")
        sys.exit(0)
    print("WARN: could not locate Keycloak resources block in ArgoCD helm values.")
    sys.exit(1)

app["spec"]["source"]["helm"]["values"] = patched
subprocess.run(
    ["kubectl", "apply", "-f", "-"],
    input=json.dumps(app),
    text=True,
    check=True,
)
print(f"Patched ArgoCD Application/keycloak helm values → limit={limit} request={request}.")
PY
}

stack_startup_patch_keycloak_memory() {
  local limit="${KEYCLOAK_MEMORY_LIMIT:-4Gi}"
  local request="${KEYCLOAK_MEMORY_REQUEST:-2Gi}"
  if ! kubectl get deployment keycloak -n keycloak &>/dev/null; then
    echo "Keycloak deployment not found — skipping memory patch."
    return 0
  fi

  if stack_startup_patch_keycloak_argocd; then
    echo "Waiting for ArgoCD to sync Keycloak deployment..."
    for _ in $(seq 1 60); do
      local current
      current=$(kubectl get deployment keycloak -n keycloak \
        -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
      if [[ "$current" == "$limit" ]]; then
        echo "Keycloak deployment synced to limit=${limit}."
        return 0
      fi
      sleep 5
    done
    echo "WARN: ArgoCD sync slow — applying direct deployment patch as fallback."
  fi

  local current
  current=$(kubectl get deployment keycloak -n keycloak \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
  if [[ "$current" == "$limit" ]]; then
    echo "Keycloak memory limit already ${limit}."
    return 0
  fi
  echo "Patching Keycloak deployment memory ${current:-unset} → limit=${limit} request=${request}..."
  kubectl patch deployment keycloak -n keycloak --type=json \
    -p="[
      {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"${limit}\"},
      {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/memory\",\"value\":\"${request}\"}
    ]"
}

stack_startup_wait_for_keycloak() {
  local timeout="${1:-600}"
  if ! kubectl get deployment keycloak -n keycloak &>/dev/null; then
    return 0
  fi
  echo "Waiting for Keycloak readiness (up to ${timeout}s)..."
  kubectl wait deployment/keycloak -n keycloak --for=condition=Available --timeout="${timeout}s" 2>/dev/null \
    || kubectl rollout status deployment/keycloak -n keycloak --timeout="${timeout}s"
}

stack_startup_cleanup_evicted_pods() {
  echo "Removing evicted / failed pods in keycloak, aiwb, airm, cluster-auth..."
  for ns in keycloak aiwb airm cluster-auth kyverno; do
    kubectl get pods -n "$ns" --field-selector=status.phase=Failed -o name 2>/dev/null \
      | xargs -r kubectl delete -n "$ns" 2>/dev/null || true
  done
}
