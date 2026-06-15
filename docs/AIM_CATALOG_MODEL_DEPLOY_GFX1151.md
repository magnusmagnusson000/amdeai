# Deploy a new AIM catalog model on gfx1151 (AI Workbench)

**Audience:** Working [Cluster Bloom](BLOOM_GFX1151_INSTALL.md) stack with AI Workbench and AIM Engine.

**Goal:** Add a model to the AIM catalog so you can click **Deploy** in AI Workbench (`/demo/models/aim-catalog`), run inference on gfx1151, and wire downstream consumers (telecom assistant, tests).

**Reference implementation:** [Qwen3.6-27B](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md) — manifests in [`manifests/aim/qwen3-6-27b/`](../manifests/aim/qwen3-6-27b/), script [`scripts/10-qwen3-6-27b.sh`](../scripts/10-qwen3-6-27b.sh).

For models that **cannot** use managed `InferenceService` on gfx1151 (standard `aim-base` segfaults), see the hybrid pattern in [GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md](GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md). This guide covers the **managed Workbench Deploy** path with a **custom gfx1151 AIM image**.

---

## Quick start (existing Qwen catalog)

If catalog CRs are already in the repo and you only need a fresh deploy:

```bash
# 1. Prerequisites
df -h /                                    # >= 120 GiB free for Qwen-scale models
bash scripts/03b-gfx1151-aim-labels.sh     # R9700 accelerator label

# 2. Catalog only (no download) — enables Deploy button
CATALOG_ONLY=1 bash scripts/10-qwen3-6-27b.sh

# 3. Deploy from AI Workbench UI
#    https://aiwbui.<domain>/demo/models/aim-catalog → Qwen card → Deploy → Confirm

# 4. Post-deploy fixes (required on gfx1151 Bloom)
bash scripts/ensure-qwen-profile-mount.sh demo
bash scripts/fix-aim-httproute-gateway.sh demo

# 5. Validate
kubectl get aimservice -n demo
kubectl logs -n demo -l component=predictor --tail=20
bash scripts/ensure-qwen-llm-bridge.sh      # if telecom or stable cluster DNS needed
bash scripts/run-e2e-stack-validation.sh    # cluster + login + catalog (no full deploy)
```

---

## Decision: which path for a new model?

| Situation | Path | Doc |
|-----------|------|-----|
| Large model on gfx1151, needs custom vLLM/PyTorch image | **Managed AIM** (this guide) | Qwen example |
| Small model, weights fit, `kyuz0/vllm-therock` works standalone | **Hybrid** (AIMService download + plain Deployment) | [GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md](GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md) |
| Host-only chat, no cluster GPU pod | **llama.cpp + AIMModel** | `scripts/07-llama-cpp.sh` |
| Model already in upstream AMD catalog with MI300X image only | Custom gfx1151 image + manifests (this guide) | — |

On Strix Halo, assume you need a **custom AIM image** for any vLLM-backed catalog model until upstream ships gfx1151 `aim-base`.

---

## What the AIM operator needs (catalog + Deploy button)

`AIMClusterModel` alone is **not** enough. The Workbench catalog filters on **Ready** `AIMClusterServiceTemplate` resources whose GPU matches the cluster (R9700 on gfx1151).

| # | Resource | Scope | Purpose |
|---|----------|-------|---------|
| 1 | `AIMClusterModel` | Cluster | Catalog entry (model id, image ref, recommended profile) |
| 2 | `AIMClusterProfile` | Cluster | vLLM engine args, gfx1151 env, custom image |
| 3 | `AIMClusterServiceTemplate` | Cluster | **Deploy button** — hardware R9700, `profileId`, env |
| 4 | Profile `ConfigMap` | Namespace (`demo`) | aim-runtime profile YAML (see mount path below) |
| 5 | `AIMRuntimeConfig` | Namespace (`demo`) | Gateway `envoy-gateway-system/https` (not `kgateway-system`) |
| 6 | Custom AIM image | Local registry `:32000` | `aim-runtime` + gfx1151 vLLM stack |

Optional: `AIMService` in YAML — only if you deploy via script/CLI instead of the UI.

---

## Adding a new model (step by step)

### 1. Plan disk and naming

```bash
df -h /
# Rule of thumb: model_weights_GiB + 60 GiB (image overlay) + 15 GiB reserve
```

Choose stable names (Qwen example):

| Concept | Example |
|---------|---------|
| Catalog model name | `qwen-qwen3-6-27b` |
| Profile / template id | `qwen3-6-27b-r9700-gfx1151-latency` |
| HuggingFace model id | `Qwen/Qwen3.6-27B` |
| Manifest directory | `manifests/aim/<your-model>/` |
| Deploy script | `scripts/10-<your-model>.sh` (copy from `10-qwen3-6-27b.sh`) |

### 2. Copy and edit manifests

```bash
cp -r manifests/aim/qwen3-6-27b manifests/aim/my-new-model
# Edit: aim-clustermodel.yaml, aim-clusterprofile.yaml,
#       aim-clusterservicetemplate.yaml, *-profile-configmap.yaml,
#       aim-runtimeconfig-demo.yaml, aim-service.yaml (optional)
```

**Profile ConfigMap:** the YAML file name must equal `AIM_PROFILE_ID` (stem of the file). Example: `qwen3-6-27b-r9700-gfx1151-latency.yaml` for `AIM_PROFILE_ID=qwen3-6-27b-r9700-gfx1151-latency`.

**Do not** set `customProfile` on `AIMClusterServiceTemplate` on gfx1151 — it creates an unresolvable `custom/...` profile path.

### 3. Custom AIM image (if needed)

Copy [`images/aim-gfx1151-qwen3-6-27b/Dockerfile`](../images/aim-gfx1151-qwen3-6-27b/Dockerfile): `aim-runtime` from `aim-base:0.11` onto `kyuz0/vllm-therock-gfx1151:stable`. Build and push to `$(hostname -s):32000`.

### 4. Node labels and gateway (once per cluster)

```bash
bash scripts/03b-gfx1151-aim-labels.sh
kubectl get aimclusterprofile <your-profile> -o jsonpath='{.status.matchingNodes}'
# Must be >= 1
```

Apply namespace `AIMRuntimeConfig` (gateway override) — see [`manifests/aim/qwen3-6-27b/aim-runtimeconfig-demo.yaml`](../manifests/aim/qwen3-6-27b/aim-runtimeconfig-demo.yaml).

### 5. Register catalog (no deploy yet)

```bash
CATALOG_ONLY=1 bash scripts/10-<your-model>.sh
kubectl get aimclusterservicetemplate <template-name> -o jsonpath='{.status.status}'
# Must be Ready
```

`CATALOG_ONLY=1` applies models, profiles, templates, profile ConfigMap, and runtime config — **skips** `AIMService` and weight download.

### 6. Deploy

**Option A — AI Workbench (recommended)**

1. Open `https://aiwbui.<domain>/demo/models/aim-catalog`
2. Sign in with Keycloak (`devuser@<domain>`)
3. Click **Deploy** on the model card → **Confirm**

Workbench creates `demo/wb-aim-<hash>` (not a fixed name like `qwen3-6-27b`).

**Option B — CLI**

```bash
bash scripts/10-<your-model>.sh    # full managed path including AIMService
```

### 7. Post-deploy fixes (gfx1151 Bloom — always run)

These are required after **every** Workbench Deploy on this stack:

```bash
# Profile YAML mount (fixes ProfileNotFound on predictor)
bash scripts/ensure-qwen-profile-mount.sh demo
# For a new model: generalize this script or add a sibling; mount path is always:
#   /workspace/aim-runtime/profiles  (ConfigMap key = <profile-id>.yaml)

# HTTPRoute parent gateway (fixes AIMService stuck Starting)
bash scripts/fix-aim-httproute-gateway.sh demo
```

**Why:** The AIM operator often omits the profile volume, and HTTPRoutes may reference deprecated `kgateway-system` while the live Gateway is in `envoy-gateway-system`.

### 8. Wait for Running

```bash
kubectl get aimservice -n demo -w
kubectl logs -n demo -l component=predictor -f
# vLLM loading ~10–30 min for 27B; metrics on :8000 when ready
```

Success criteria:

```bash
kubectl get aimservice -n demo -o jsonpath='{.items[0].status.status}'   # Running
kubectl describe httproute -n demo | grep -A2 "Accepted"                # True
```

In-cluster smoke:

```bash
POD=$(kubectl get pod -n demo -l component=predictor -o jsonpath='{.items[?(@.status.containerStatuses[0].ready)].metadata.name}')
kubectl exec -n demo "$POD" -- curl -sf http://127.0.0.1:8000/v1/models | head -c 200
```

### 9. Downstream consumers (telecom assistant)

Telecom expects a **stable DNS name**, not `wb-aim-*`:

```bash
bash scripts/ensure-qwen-llm-bridge.sh
kubectl get endpoints qwen3-6-27b-llm -n default
# Then: TELECOM_SKIP_BUILD=1 bash scripts/09-telecom-assistant.sh
```

See [TELECOM_ASSISTANT_GFX1151_ADAPTATION.md](TELECOM_ASSISTANT_GFX1151_ADAPTATION.md).

---

## Replace or remove an existing model

Before deploying a new instance (or re-running the one-time E2E deploy test):

```bash
# Delete Workbench AIMService (name varies: wb-aim-*)
kubectl get aimservice -n demo
kubectl delete aimservice wb-aim-<hash> -n demo --wait=true --timeout=180s

# Stop template-cache from re-downloading weights
kubectl delete aimtemplatecache -n demo -l aim.eai.amd.com/cluster-model.name=qwen-qwen3-6-27b --ignore-not-found
kubectl delete aimartifact -n demo -l aim.eai.amd.com/model=qwen-qwen3-6-27b --ignore-not-found 2>/dev/null || true

# Remove weight PVCs (frees ~52 GiB per Qwen-scale model)
kubectl get pvc -n demo | grep -i qwen
kubectl patch pvc <name> -n demo --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
kubectl delete pvc <name> -n demo --force --grace-period=0

# Prune orphaned local-path data if PVC stuck Terminating
sudo rm -rf /opt/local-path-provisioner/*qwen*
```

Check disk after cleanup: `df -h /` (target **≥ 120 GiB** free before a full Qwen redeploy).

---

## Validation (automated)

| Test | Command | When |
|------|---------|------|
| Stack + login + catalog + Deploy dialog (cancel) | `bash scripts/run-e2e-stack-validation.sh` | After catalog prep; safe for CI |
| One-time full Deploy confirm (~52 GiB) | `E2E_QWEN_DEPLOY=1 pytest tests/e2e/test_aiwb_ui.py::test_qwen_deploy_confirm_full -v -s` | Manual only; deletes existing deploy |
| Card status (model already Running) | `E2E_AIWB=1 pytest tests/e2e/test_aiwb_ui.py::test_qwen_card_status -v` | After successful deploy |

The full deploy test runs post-deploy scripts (`ensure-qwen-profile-mount`, waits for `Running`). Generalize selectors when adding a non-Qwen model.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| No **Deploy** button on catalog card | Template not Ready or GPU mismatch | `03b-gfx1151-aim-labels.sh`; `CATALOG_ONLY=1` script; `kubectl get aimclusterservicetemplate` |
| `ProfileNotFound: '<profile-id>' not found` | Profile ConfigMap not mounted | `bash scripts/ensure-qwen-profile-mount.sh demo` — mount at `/workspace/aim-runtime/profiles` |
| `AIMService` stuck **Starting**, HTTPRoute empty | Route parent `kgateway-system` | `bash scripts/fix-aim-httproute-gateway.sh demo` |
| Predictor **CrashLoopBackOff** after profile fix | Wrong mount path (`profiles/qwen/...` only) | Remount at `/workspace/aim-runtime/profiles` (flat) |
| Weights re-download after delete | `AIMTemplateCache` left behind | `kubectl delete aimtemplatecache -n demo ...` |
| PVC stuck **Terminating** | Finalizers / Kyverno | Patch finalizers; `fix-web-uis.sh` if Kyverno down |
| `Insufficient amd.com/gpu` | Another pod holds GPU | `kubectl get pods -A -o wide \| grep Running` on GPU workloads |
| UI **403** / Keycloak OOM | Disk pressure | `bash scripts/fix-web-uis.sh` |
| Telecom agent LLM timeout | Bridge endpoints empty | `bash scripts/ensure-qwen-llm-bridge.sh` |
| E2E waits forever on `wb-aim-*` | Test filtered on name `qwen` only | Match `spec.model.name` or `aim.eai.amd.com/model` label |

### Useful commands

```bash
kubectl get aimservice,aimartifact,aimtemplatecache,inferenceservice,httproute,pvc -n demo
kubectl describe aimservice -n demo
kubectl logs -n demo -l component=predictor --tail=50
kubectl get gateway -n envoy-gateway-system
df -h /
```

---

## File checklist for a new model

```
manifests/aim/<model>/
  aim-clustermodel.yaml
  aim-clusterprofile.yaml
  aim-clusterservicetemplate.yaml
  <profile-id>-profile-configmap.yaml
  aim-runtimeconfig-demo.yaml
  aim-service.yaml              # optional CLI deploy
images/aim-gfx1151-<model>/Dockerfile   # if custom image needed
scripts/10-<model>.sh           # CATALOG_ONLY=1 support
scripts/ensure-<model>-profile-mount.sh   # or generalize ensure-qwen-profile-mount.sh
docs/<MODEL>_AIM_GFX1151_POST_INSTALL.md  # model-specific notes (optional)
```

---

## Related docs

- [QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md) — full Qwen walkthrough, image build, smoke tests
- [GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md](GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md) — hybrid / Phi-4 path
- [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md) — cluster prerequisites, E2E commands
- [TELECOM_ASSISTANT_SPEECH_TESTING.md](TELECOM_ASSISTANT_SPEECH_TESTING.md) — after LLM is Running
- [AIM_ENGINE_DEEP_DIVE.md](AIM_ENGINE_DEEP_DIVE.md) — CRD reference
