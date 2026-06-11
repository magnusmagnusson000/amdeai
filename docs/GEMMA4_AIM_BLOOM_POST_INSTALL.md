# Gemma 4 AIM in AI Workbench — post-Bloom install guide

**Audience:** Host with a **working Cluster Bloom** installation ([`bloom-gfx1151.yaml`](../bloom-gfx1151.yaml), [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md)).

**Goal:** Register Gemma 4 as an `AIMModel` so it appears in **AMD AI Workbench** (`https://aiwbui.<IP>.nip.io`) and chat requests reach host `llama-server`.

Bloom installs Kubernetes, AIM Engine, Keycloak, and AI Workbench. It does **not** install host-side inference or register local GGUF models. That is a separate post-install step documented here.

**Pattern:** local GGUF → host `llama-server` → Kubernetes `Service`/`Endpoints` bridge → `AIMModel` catalog stub → AI Workbench UI.

Do **not** apply managed `AIMService` manifests with `hf://google/gemma-4-*` on gfx1151 — that triggers a 70+ GiB Hugging Face download and duplicates weights you already have as GGUF.

---

## Prerequisites (verify Bloom is healthy)

Set your node IP and domain (must match [`bloom-gfx1151.yaml`](../bloom-gfx1151.yaml) `DOMAIN`):

```bash
export NODE_IP=$(hostname -I | awk '{print $1}')
export DOMAIN="${NODE_IP}.nip.io"
```

### Cluster and platform

```bash
kubectl get nodes
kubectl get gateway -n envoy-gateway-system
kubectl wait --for=condition=ready pod --all -n aiwb --timeout=300s
kubectl wait --for=condition=ready pod --all -n aim-system --timeout=300s
```

### AIM Engine CRDs

```bash
kubectl get crd aimmodels.aim.eai.amd.com
kubectl get pods -n aim-system
```

### AI Workbench HTTPS

```bash
curl -sk -o /dev/null -w "%{http_code}\n" "https://aiwbui.${DOMAIN}/"
# 200 or 307 (redirect to Keycloak) is OK
```

### Host GPU / ROCm (gfx1151)

```bash
rocminfo | grep gfx1151
# GTT pool should be ~128 GiB after Bloom GRUB config (not ~4 GiB vis_vram only)
```

### Model weights on disk

| Variant | GGUF path | Host port | OpenAI model id |
|---------|-----------|-----------|-----------------|
| **Gemma 4 26B-A4B** (primary Workbench chat) | `~/models/gemma-4-26b-a4b-it-Q4_K_M.gguf` | `8080` | `gemma-4` |
| **Gemma 4 31B** (optional, denser) | `~/models/gemma-4-31b-it-Q4_K_M.gguf` | `8081` | `gemma-4-31b` |

Symlinks are fine. Only one variant should load the GPU at a time.

### llama.cpp HIP binary

Build once on branch `gfx1151-rdna35-tuning` (see [gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md)):

```bash
cd ~/eai-build/llama.cpp
cmake -S . -B build-hip \
  -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 \
  -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DLLAMA_CURL=ON
cmake --build build-hip -j"$(nproc)"
test -x build-hip/bin/llama-server && echo OK
```

---

## Configuration files in this repo

### Kubernetes manifests (AIM registration)

| File | Purpose |
|------|---------|
| [`manifests/aim/gemma-4-26b-a4b/service-bridge.yaml`](../manifests/aim/gemma-4-26b-a4b/service-bridge.yaml) | `Service` + `Endpoints` → host `:8080` |
| [`manifests/aim/gemma-4-26b-a4b/aimmodel.yaml`](../manifests/aim/gemma-4-26b-a4b/aimmodel.yaml) | `AIMModel` catalog entry (26B-A4B) |
| [`manifests/aim/gemma-4-31b/service-bridge.yaml`](../manifests/aim/gemma-4-31b/service-bridge.yaml) | `Service` + `Endpoints` → host `:8081` |
| [`manifests/aim/gemma-4-31b/aimmodel.yaml`](../manifests/aim/gemma-4-31b/aimmodel.yaml) | `AIMModel` catalog entry (31B) |

Manifests use `${NODE_IP}` placeholders. Substitute with `envsubst` before `kubectl apply`.

**Reference only (do not apply on gfx1151):**

| File | Purpose |
|------|---------|
| [`manifests/aim/gemma-4-31b/aim-clustermodel.yaml`](../manifests/aim/gemma-4-31b/aim-clustermodel.yaml) | Future managed-image catalog stub |

### Host systemd units (inference, not Kubernetes)

| File | Port | systemd unit name |
|------|------|-------------------|
| [`manifests/host/llama-gemma-26b-a4b.service`](../manifests/host/llama-gemma-26b-a4b.service) | `8080` | `llama-gemma.service` |
| [`manifests/host/llama-gemma-31b.service`](../manifests/host/llama-gemma-31b.service) | `8081` | `llama-gemma-31b.service` |

Copy to `~/.config/systemd/user/`, adjust `WorkingDirectory`, `ExecStart` model path, and binary path if your tree differs from `~/eai-build/llama.cpp`.

### Bloom config (already applied)

| File | Relevant fields |
|------|-----------------|
| [`bloom-gfx1151.yaml`](../bloom-gfx1151.yaml) | `DOMAIN`, `GPU_GFX1151`, `NO_DISKS_FOR_CLUSTER` |

No changes to Bloom config are required for Gemma 4 AIM registration.

---

## Step 1 — Start host llama-server

Pick **one** variant.

### Option A — Gemma 4 26B-A4B (recommended for Workbench)

```bash
mkdir -p ~/.config/systemd/user
cp /home/magnus/projects/amdeai/manifests/host/llama-gemma-26b-a4b.service \
   ~/.config/systemd/user/llama-gemma.service
systemctl --user daemon-reload
systemctl --user enable --now llama-gemma.service
```

### Option B — Gemma 4 31B

```bash
mkdir -p ~/.config/systemd/user
cp /home/magnus/projects/amdeai/manifests/host/llama-gemma-31b.service \
   ~/.config/systemd/user/llama-gemma-31b.service
systemctl --user daemon-reload
systemctl --user enable --now llama-gemma-31b.service
```

### Verify inference is up

```bash
# 26B-A4B
curl -sf http://localhost:8080/health

# 31B
curl -sf http://localhost:8081/health
```

Smoke test from the host:

```bash
# 26B-A4B
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4","messages":[{"role":"user","content":"Hi"}],"max_tokens":16}'

# 31B
curl -s http://localhost:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-31b","messages":[{"role":"user","content":"Hi"}],"max_tokens":16}'
```

If the service fails, inspect logs:

```bash
journalctl --user -u llama-gemma.service -n 50 --no-pager
journalctl --user -u llama-gemma-31b.service -n 50 --no-pager
```

---

## Step 2 — Register AIMModel (kubectl)

Export `NODE_IP` (same value Bloom uses for MetalLB / gateway):

```bash
export NODE_IP=$(hostname -I | awk '{print $1}')
cd /home/magnus/projects/amdeai
```

### Option A — Gemma 4 26B-A4B

Apply the service bridge, then the catalog entry:

```bash
envsubst < manifests/aim/gemma-4-26b-a4b/service-bridge.yaml | kubectl apply -f -
envsubst < manifests/aim/gemma-4-26b-a4b/aimmodel.yaml | kubectl apply -f -
```

### Option B — Gemma 4 31B

```bash
envsubst < manifests/aim/gemma-4-31b/service-bridge.yaml | kubectl apply -f -
envsubst < manifests/aim/gemma-4-31b/aimmodel.yaml | kubectl apply -f -
```

Both register in namespace **`default`**, which is the usual Workbench catalog scope.

**Telecom assistant note:** If you need the 31B bridge in namespace `demo` instead, edit `namespace:` in both YAML files to `demo` before applying, or duplicate the manifests under a `demo` overlay.

### Wait for Ready

```bash
# 26B-A4B
kubectl wait --for=jsonpath='{.status.status}'=Ready \
  aimmodel/gemma-4-26b-a4b-local -n default --timeout=120s

# 31B
kubectl wait --for=jsonpath='{.status.status}'=Ready \
  aimmodel/gemma-4-31b-local -n default --timeout=120s
```

### Inspect registration

```bash
# 26B-A4B
kubectl get aimmodel,svc,endpoints gemma-4-26b-a4b-local -n default
kubectl describe aimmodel gemma-4-26b-a4b-local -n default

# 31B
kubectl get aimmodel,svc,endpoints gemma-4-31b-local -n default
kubectl describe aimmodel gemma-4-31b-local -n default
```

Expected `AIMModel` annotations:

| Annotation | 26B-A4B | 31B |
|------------|---------|-----|
| `aim.eai.amd.com/display-name` | `Gemma 4 26B-A4B (local Q4_K_M)` | `Gemma 4 31B (local Q4_K_M)` |
| `aim.eai.amd.com/external-endpoint` | `http://<NODE_IP>:8080` | `http://<NODE_IP>:8081` |
| `aim.eai.amd.com/model-id` | `gemma-4` | `gemma-4-31b` |

### In-cluster endpoint (for pods calling the LLM)

```bash
# 26B-A4B
curl -sf "http://gemma-4-26b-a4b-local.default.svc.cluster.local:8080/health"

# 31B
curl -sf "http://gemma-4-31b-local.default.svc.cluster.local:8081/health"
```

Test from a debug pod if host firewall is a concern:

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sf "http://gemma-4-26b-a4b-local.default.svc.cluster.local:8080/health"
```

---

## Step 3 — Confirm in AI Workbench UI

1. Open `https://aiwbui.${DOMAIN}`.
2. Click **Sign in with Keycloak**.
3. Log in as `devuser@${DOMAIN}`.

   Password:

   ```bash
   kubectl -n keycloak get secret airm-realm-credentials \
     -o jsonpath='{.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}' | base64 --decode && echo
   ```

4. Go to **Models** (`/models`) or the model picker in **Chat**.
5. Select:
   - **Gemma 4 26B-A4B (local Q4_K_M)**, or
   - **Gemma 4 31B (local Q4_K_M)**.
6. Send a test prompt and confirm streaming reply.

---

## Cleanup / teardown

### Remove AIM registration only

```bash
# 26B-A4B
kubectl delete aimmodel,svc,endpoints gemma-4-26b-a4b-local -n default --ignore-not-found

# 31B
kubectl delete aimmodel,svc,endpoints gemma-4-31b-local -n default --ignore-not-found
```

### Stop host inference

```bash
systemctl --user stop llama-gemma.service
systemctl --user stop llama-gemma-31b.service
```

### Remove stale managed HF Gemma (if accidentally applied)

```bash
kubectl delete aimservice gemma-4-31b-chat -n default --ignore-not-found
kubectl delete aimservice gemma-4-31b-chat -n demo --ignore-not-found
kubectl get aimartifact,aimprofilecache,inferenceservice -A -o name | grep -i gemma | \
  xargs -r kubectl delete --ignore-not-found
kubectl delete aimclusterprofile google-gemma-4-31b-r9700-latency --ignore-not-found
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Model missing in Workbench | `kubectl get aimmodel -n default`; status must be `Ready` |
| `AIMModel` not Ready | `kubectl describe aimmodel …`; confirm AIM Engine pods in `aim-system` |
| Model listed, chat fails | `curl http://localhost:8080/health` (or `:8081`); `systemctl --user status …` |
| In-cluster curl fails, host OK | `Endpoints` IP must match `NODE_IP`; re-run `envsubst` apply after IP change |
| Wrong display name in UI | Edit `aim.eai.amd.com/display-name` on the `AIMModel` and re-apply |
| Disk filling up | Delete any `AIMService` / PVC tied to `hf://google/gemma-4-*` |

---

## Related docs

| Doc | Topic |
|-----|-------|
| [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md) | Bloom install and credentials |
| [AIM_ENGINE_DEEP_DIVE.md](AIM_ENGINE_DEEP_DIVE.md) §8.4 | External endpoint registration pattern |
| [call-flows/06b-airm-aiwb.md](call-flows/06b-airm-aiwb.md) | Workbench request path |
| [call-flows/07-llama-cpp.md](call-flows/07-llama-cpp.md) | 26B-A4B inference path |
| [call-flows/08-gemma4-31b.md](call-flows/08-gemma4-31b.md) | 31B inference path |
| [gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md) | llama.cpp HIP build on gfx1151 |
