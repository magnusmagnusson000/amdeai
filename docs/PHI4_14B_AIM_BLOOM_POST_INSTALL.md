# Phi-4 14B AIM in AI Workbench — post-Bloom install guide

**Audience:** Host with a **working Cluster Bloom** installation ([`bloom-gfx1151.yaml`](../bloom-gfx1151.yaml), [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md)).

**Goal:** Register and deploy **microsoft/phi-4** (14B fp16) as a managed `AIMService` so it appears in **AMD AI Workbench** (`https://aiwbui.<IP>.nip.io`) and can serve chat, optional telecom tool-calling, and automated tests.

**Pattern:** Custom gfx1151 AIM image → `AIMClusterModel` / `AIMClusterProfile` / `AIMClusterServiceTemplate` → Workbench **Deploy** → `InferenceService` predictor → vLLM on gfx1151.

> **Generic playbook:** [AIM_CATALOG_MODEL_DEPLOY_GFX1151.md](AIM_CATALOG_MODEL_DEPLOY_GFX1151.md). This document is the **Phi-4 14B-specific** deep dive.

> **GPU exclusivity:** Pause **DiffusionGemma** (and other AIM predictors) before deploying Phi-4 — single GPU on gfx1151. Run `bash scripts/ensure-diffusiongemma-paused.sh` first.

---

## Prerequisites (verify Bloom is healthy)

```bash
export NODE_IP=$(hostname -I | awk '{print $1}')
export DOMAIN="${NODE_IP}.nip.io"
```

### Cluster and platform

```bash
kubectl get nodes
kubectl wait --for=condition=ready pod --all -n aiwb --timeout=300s
kubectl wait --for=condition=ready pod --all -n aim-system --timeout=300s
kubectl get crd aimmodels.aim.eai.amd.com
df -h /   # >= 45 GiB free for Phi-4 weights + image
```

### Pause DiffusionGemma (required before Phi-4)

```bash
bash scripts/ensure-diffusiongemma-paused.sh demo default
kubectl get pods -A -l aim.eai.amd.com/model=google-diffusiongemma-26b,component=predictor
# Expect: no Running pods
```

### Host GPU / ROCm (gfx1151)

```bash
rocminfo | grep gfx1151
bash scripts/03b-gfx1151-aim-labels.sh   # R9700 accelerator label
```

| Requirement | Notes |
|-------------|-------|
| Model weights | `hf://microsoft/phi-4` (~28 GiB fp16), no HF token |
| Disk | **≥ 45 GiB** free on `/` |
| Swap | **≥ 8 GiB** recommended ([DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md](DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md)) |
| Custom image | `$(hostname -s):32000/aim-gfx1151-phi-4-14b:0.11-therock` |

---

## Configuration files in this repo

### Kubernetes manifests (AIM catalog + deploy)

| File | Purpose |
|------|---------|
| [`manifests/aim/phi-4-14b/aim-clustermodel.yaml`](../manifests/aim/phi-4-14b/aim-clustermodel.yaml) | Catalog entry `microsoft-phi-4-14b` |
| [`manifests/aim/phi-4-14b/aim-clusterprofile.yaml`](../manifests/aim/phi-4-14b/aim-clusterprofile.yaml) | vLLM runtime profile (gfx1151) |
| [`manifests/aim/phi-4-14b/aim-clusterservicetemplate.yaml`](../manifests/aim/phi-4-14b/aim-clusterservicetemplate.yaml) | Workbench **Deploy** button |
| [`manifests/aim/phi-4-14b/phi-4-14b-r9700-gfx1151-latency-profile-configmap.yaml`](../manifests/aim/phi-4-14b/phi-4-14b-r9700-gfx1151-latency-profile-configmap.yaml) | Profile YAML for aim-runtime |
| [`manifests/aim/phi-4-14b/aim-runtimeconfig-demo.yaml`](../manifests/aim/phi-4-14b/aim-runtimeconfig-demo.yaml) | Gateway `envoy-gateway-system/https` |
| [`manifests/aim/phi-4-14b/aim-service.yaml`](../manifests/aim/phi-4-14b/aim-service.yaml) | Optional CLI deploy trigger |

### Custom AIM image

| File | Purpose |
|------|---------|
| [`images/aim-gfx1151-phi-4-14b/Dockerfile`](../images/aim-gfx1151-phi-4-14b/Dockerfile) | `aim-runtime` + `kyuz0/vllm-therock-gfx1151:stable` |

### Scripts

| Script | Purpose |
|--------|---------|
| [`scripts/13-phi-4-14b.sh`](../scripts/13-phi-4-14b.sh) | Catalog + optional full deploy |
| [`scripts/ensure-diffusiongemma-paused.sh`](../scripts/ensure-diffusiongemma-paused.sh) | **Stop DG before Phi-4** |
| [`scripts/ensure-phi-4-14b-profile-mount.sh`](../scripts/ensure-phi-4-14b-profile-mount.sh) | Fix `ProfileNotFound` |
| [`scripts/ensure-phi-4-14b-chattable.sh`](../scripts/ensure-phi-4-14b-chattable.sh) | Chat model picker |
| [`scripts/ensure-phi-4-tool-calling.sh`](../scripts/ensure-phi-4-tool-calling.sh) | Tool-calling profile + spike |
| [`scripts/ensure-phi-4-llm-bridge.sh`](../scripts/ensure-phi-4-llm-bridge.sh) | Telecom stable DNS |

### Telecom (optional)

| File | Purpose |
|------|---------|
| [`manifests/telecom-assistant/phi-4-llm-bridge.yaml`](../manifests/telecom-assistant/phi-4-llm-bridge.yaml) | `phi-4-llm.default.svc.cluster.local` |
| [`manifests/telecom-assistant/values-eai-local-phi4.yaml`](../manifests/telecom-assistant/values-eai-local-phi4.yaml) | Helm overlay for telecom LLM leg |

---

## Step 1 — Pause DiffusionGemma and register catalog

```bash
cd /home/magnus/projects/amdeai
bash scripts/ensure-diffusiongemma-paused.sh demo default
CATALOG_ONLY=1 bash scripts/13-phi-4-14b.sh
```

Verify:

```bash
kubectl get aimclusterservicetemplate phi-4-14b-r9700-gfx1151-latency -o jsonpath='{.status.status}'
# Ready
kubectl get aimclusterprofile phi-4-14b-r9700-gfx1151-latency -o jsonpath='{.status.matchingNodes}'
# >= 1
```

---

## Step 2 — Deploy (Workbench or CLI)

### Option A — AI Workbench (recommended)

1. Open `https://aiwbui.${DOMAIN}/demo/models/aim-catalog`
2. Sign in with Keycloak (`devuser@${DOMAIN}`)
3. Find **microsoft-phi-4-14b** → **Deploy** → **Confirm**
4. Wait for AIMService status **Running** (~15–30 min first run: download + load)

### Option B — CLI

```bash
bash scripts/ensure-diffusiongemma-paused.sh demo default
bash scripts/13-phi-4-14b.sh
```

---

## Step 3 — Post-deploy fixes (gfx1151 Bloom — always run)

```bash
bash scripts/ensure-phi-4-14b-profile-mount.sh demo
bash scripts/fix-aim-httproute-gateway.sh demo
bash scripts/ensure-phi-4-14b-chattable.sh
bash scripts/ensure-phi-4-llm-bridge.sh
```

In-cluster smoke:

```bash
kubectl run curl-phi4 --rm -it --restart=Never --image=curlimages/curl -n demo -- \
  curl -sf http://phi-4-llm.default.svc.cluster.local/v1/models
```

---

## Step 4 — Confirm in AI Workbench UI

1. Open `https://aiwbui.${DOMAIN}/demo/chat`
2. **Select model** → Phi-4 entry
3. Send: `Reply with exactly: pong`

---

## Step 5 — Tool calling (telecom validation)

Experimental on 14B — uses `phi4_mini_json` parser. Validate before switching telecom:

```bash
bash scripts/ensure-phi-4-tool-calling.sh demo
```

If spike fails, keep DiffusionGemma as telecom default ([TELECOM_ASSISTANT_GFX1151_ADAPTATION.md](TELECOM_ASSISTANT_GFX1151_ADAPTATION.md)). Phi-4 remains available for Workbench chat.

Optional telecom overlay:

```bash
# After spike passes:
helm upgrade ... -f manifests/telecom-assistant/values-eai-local.yaml \
  -f manifests/telecom-assistant/values-eai-local-phi4.yaml
```

---

## Cleanup / teardown

```bash
kubectl delete aimservice phi-4-14b -n demo --ignore-not-found
kubectl get pvc -n demo | grep -i phi
# Delete weight PVCs if reclaiming disk
bash scripts/ensure-diffusiongemma-paused.sh   # already paused; to resume DG later:
# patch AIMService replicas back to 1 and re-Deploy from Workbench
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| OOM / CrashLoop on predictor | Lower `gpu-memory-utilization` (profile uses `0.38`); ensure DG paused |
| Model missing in catalog | `kubectl get aimclusterservicetemplate phi-4-14b-r9700-gfx1151-latency` → `Ready` |
| `ProfileNotFound` | `bash scripts/ensure-phi-4-14b-profile-mount.sh demo` |
| Chat model empty | `bash scripts/ensure-phi-4-14b-chattable.sh` |
| DG still consuming GPU | `bash scripts/ensure-diffusiongemma-paused.sh`; verify no Running DG predictor pods |
| Tool calls empty (`finish_reason: stop`) | Known risk on 14B — use phi4-mini or DiffusionGemma for telecom |
| `enforce-eager` argparse error | Use YAML boolean `true`, not `"true"` string ([QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md)) |
| disk-pressure Pending | Free disk; see Qwen post-install disk-pressure section |
| HIP page faults | Remove `amdgpu-dkms`; use OEM kernel ([gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md)) |

---

## Automated validation

| Test | Command |
|------|---------|
| Catalog template | `pytest tests/integration/test_phi4_14b_aim.py::test_phi4_catalog_template_ready -v` |
| Stack + catalog (E2E prep) | `E2E_STACK=1 E2E_PHI4=1 pytest tests/e2e/test_stack_health.py::test_stack_phi4_catalog_ready -v` |
| Catalog UI (non-destructive) | `E2E_AIWB=1 E2E_PHI4=1 pytest tests/e2e/test_aiwb_ui.py -k "phi4 and not deploy_confirm" -v` |
| Full deploy (destructive) | `E2E_PHI4_DEPLOY=1 pytest tests/e2e/test_aiwb_ui.py::test_phi4_deploy_confirm_full -v -s` |
| After deploy | `PHI4_AIM_DEPLOYED=1 pytest tests/integration/test_phi4_14b_aim.py -v` |
| Telecom bridge | `TELECOM_LLM=phi4 PHI4_TOOL_CALLING=1 pytest tests/integration/test_telecom_assistant.py -k phi4 -v` |

---

## Related docs

| Doc | Topic |
|-----|-------|
| [GEMMA4_AIM_BLOOM_POST_INSTALL.md](GEMMA4_AIM_BLOOM_POST_INSTALL.md) | Local GGUF pattern (host llama-server) |
| [GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md](GFX1151_CUSTOM_AIM_DEPLOYMENT_GUIDE.md) | Phi-4-mini hybrid reference |
| [QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md](QWEN3_6_27B_AIM_GFX1151_POST_INSTALL.md) | Managed catalog reference |
| [DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md](DIFFUSIONGEMMA_26B_AIM_GFX1151_POST_INSTALL.md) | Memory tuning; pause before Phi-4 |
| [call-flows/10-phi-4-14b.md](call-flows/10-phi-4-14b.md) | Inference request path |
