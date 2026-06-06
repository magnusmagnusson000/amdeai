# AMD Enterprise AI Suite — Z13 (amdeai)

Automation, documentation, and tests for the [AMD Enterprise AI Suite](eai-suite-z13-guide.md) on Asus Z13 (Radeon 8060S, **gfx1151**, 128 GB RAM, Ubuntu 24.04).

**Standard inference path:** ROCm HIP in Kubernetes (Kaiwo → vLLM → gfx1151)  
**Local Workbench chat:** llama.cpp on host port 8080 (Vulkan for Gemma 4; HIP for SLMs)  
**gfx1151 patches:** [docs/gfx1151-upstream-pr-guide.md](docs/gfx1151-upstream-pr-guide.md)

---

## Quick start — full system install

Run scripts in order. Most steps need **sudo** (k3s, ROCm, GRUB). Set `HF_TOKEN` before step 06b.

```bash
cd /home/magnus/projects/amdeai

# Optional: refresh all study-tree repos
bash scripts/sync-eai-build.sh

# Full pipeline
bash scripts/lib/disk-report.sh baseline --baseline
bash scripts/00-prerequisites.sh
bash scripts/01-host-rocm.sh          # may require REBOOT — see below
# *** reboot if 01-host-rocm.sh says REBOOT REQUIRED ***
bash scripts/02-kubernetes.sh         # k3s + local registry :32000
bash scripts/03-gpu-plugin.sh         # amd.com/gpu + gfx1151 env
bash scripts/04-platform.sh           # cert-manager, MetalLB, Longhorn, …
bash scripts/05a-cluster-forge.sh     # ArgoCD, Gitea, GitOps
bash scripts/05b-kaiwo.sh             # Kaiwo + Kueue amd-gfx1151 flavor
bash scripts/06a-aim-engine.sh        # AIM Engine + CRDs
HF_TOKEN=... bash scripts/06b-airm-workbench.sh
bash scripts/07-llama-cpp.sh          # llama-server + AIMModel CR
```

Or run everything: `bash scripts/run-all.sh` (requires sudo + `HF_TOKEN`).

**Python venv (tests):**

```bash
source /home/magnus/projects/venvs/amd/bin/activate
pip install -r tests/requirements.txt
playwright install chromium
```

---

## Step-by-step guide

### Step 0 — Prerequisites (`00-prerequisites.sh`)

Installs Go, Helm, kubectl, CMake, Docker, and the Python test venv.

```bash
bash scripts/00-prerequisites.sh
```

### Step 1 — ROCm host stack (`01-host-rocm.sh`)

- Installs ROCm 7.2.x from AMD apt repo
- Configures GRUB for 128 GiB GTT visibility on Strix Halo
- Sets `HSA_OVERRIDE_GFX_VERSION=11.5.1` in `/etc/environment`

```bash
bash scripts/01-host-rocm.sh
```

**If the script prints `REBOOT REQUIRED`**, reboot before continuing:

```bash
sudo reboot
```

After reboot, verify:

```bash
rocminfo | grep gfx
rocm-smi --showmeminfo vram    # should show ~128 GiB, not ~4 GiB
```

Optional: align GRUB with guide values: `EAI_GRUB_APPLY_GUIDE_VALUES=1 bash scripts/01-host-rocm.sh`

### Step 2 — Kubernetes / k3s (`02-kubernetes.sh`)

Installs a **single-node k3s** cluster (or k3d fallback without sudo):

| Item | Value |
|------|-------|
| API | `https://127.0.0.1:6443` (kubeconfig in `~/.kube/config`) |
| Local registry | `localhost:32000` (NodePort) |
| Mirrors | `/etc/rancher/k3s/registries.yaml` |

```bash
bash scripts/02-kubernetes.sh
kubectl get nodes
curl -sf http://localhost:32000/v2/ && echo "registry OK"
```

**k3s install details** (what the script runs):

- Disables bundled Traefik and ServiceLB (MetalLB used instead)
- Enables privileged containers (GPU device plugin)
- Deploys `registry:2` on NodePort **32000**
- Disables swap (kubelet requirement)

**Skip reboot check** (not recommended): `EAI_SKIP_REBOOT_CHECK=1 bash scripts/02-kubernetes.sh`

### Step 3 — GPU device plugin (`03-gpu-plugin.sh`)

Builds `localhost:32000/amd-gpu-device-plugin:latest`, deploys DaemonSet with gfx1151 env vars, labels node for Kaiwo.

```bash
bash scripts/03-gpu-plugin.sh
kubectl get node -o custom-columns=NAME:.metadata.name,GPU:status.capacity.amd\\.com/gpu
```

### Step 4 — Platform layer (`04-platform.sh`)

Helm install: cert-manager, MetalLB, Longhorn, Gateway API, Kueue, KubeRay, KServe.

```bash
bash scripts/04-platform.sh
```

### Step 5a — cluster-forge (`05a-cluster-forge.sh`)

GitOps bootstrap: ArgoCD, Gitea, OpenBao. Several apps disabled for minimal Z13 setup (AIRM/Keycloak via 06b).

```bash
bash scripts/05a-cluster-forge.sh
```

### Step 5b — Kaiwo (`05b-kaiwo.sh`)

Kaiwo operator + Kueue `ResourceFlavor` **amd-gfx1151** (1 GPU quota).

```bash
bash scripts/05b-kaiwo.sh
kubectl get pods -n kaiwo-system
```

### Step 6a — AIM Engine (`06a-aim-engine.sh`)

AIM Engine operator and CRDs for `AIMModel` registration.

```bash
bash scripts/06a-aim-engine.sh
```

### Step 6b — AIRM + AI Workbench (`06b-airm-workbench.sh`)

Requires Hugging Face token for model catalog features.

```bash
export HF_TOKEN=hf_...
bash scripts/06b-airm-workbench.sh
```

**URLs** (replace `<IP>` with node IP, e.g. from `hostname -I`):

| Service | URL |
|---------|-----|
| AI Workbench | `https://aiwbui.<IP>.nip.io` |
| AIRM | `https://airmui.<IP>.nip.io` |
| Keycloak | `https://keycloak.<IP>.nip.io` |

Default user: `silogen-admin` (password set at bootstrap).

### Step 7 — llama.cpp (`07-llama-cpp.sh`)

Builds llama.cpp from `~/eai-build/llama.cpp` (branch **`gfx1151-rdna35-tuning`**), starts systemd user service, registers AIMModel.

```bash
# Default: Vulkan backend for Gemma 4
bash scripts/07-llama-cpp.sh

# Also build HIP binary (for SLM testing)
EAI_LLAMA_BUILD_HIP=1 bash scripts/07-llama-cpp.sh

# Use HIP backend for llama-server (after validating SLMs)
EAI_LLAMA_BACKEND=hip bash scripts/07-llama-cpp.sh
```

Place Gemma GGUF at `~/models/gemma-4-26b-a4b-it-Q4_K_M.gguf` or set `MODEL_PATH=...`.

**Local server:** `http://<node-ip>:8080` (OpenAI-compatible, no auth).

---

## gfx1151 / ROCm notes

| Topic | Action |
|-------|--------|
| HIP kernel fixes | Branch `gfx1151-rdna35-tuning` in `~/eai-build/llama.cpp` |
| Upstream PR guide | [docs/gfx1151-upstream-pr-guide.md](docs/gfx1151-upstream-pr-guide.md) |
| Gemma 4 on HIP | Use Vulkan (`EAI_LLAMA_BACKEND=vulkan`) until #21416 resolved |
| SLM test models | Qwen3-0.6B, phi-4-mini Q4_K_M |
| Firmware MES | Avoid 0x83 hang — see upstream guide |
| Sync repos | `bash scripts/sync-eai-build.sh` |

**Host GRUB (your system vs guide):**

| Parameter | Typical Z13 | Guide |
|-----------|-------------|-------|
| `amdgpu.gttsize` | 110000 | 131072 |
| `ttm.pages_limit` | 12582912 | 33554432 |
| `amd_iommu` | — | off |

---

## Build tree and branches

**Study tree:** `~/eai-build/` — see `~/eai-build/STACK_INDEX.md`

**Feature branches:**

| Repo | Branch | Purpose |
|------|--------|---------|
| `~/eai-build/llama.cpp` | `gfx1151-rdna35-tuning` | MMVQ/MMQ/MoE gfx1151 patches |
| `amdeai` (this repo) | `gfx1151-rocm-enable` | Scripts, docs, install automation |

Refresh study sources: `bash scripts/fetch-study-sources.sh`  
Pull latest: `bash scripts/sync-eai-build.sh`

---

## Call flows

- **[End-to-end overview](docs/CALL_FLOW_OVERVIEW.md)** — standard ROCm path + local llama.cpp path
- **[Full stack overview](docs/OVERVIEW.md)** — per-repository chapters
- **[Per-component docs](docs/call-flows/)** — linked from README repository sections below

---

## Force rebuild (default)

Every script sets **`EAI_FORCE_REBUILD=1`** by default (fresh clones, `--no-cache` Docker, Helm reinstall).  
To allow skips: `EAI_FORCE_REBUILD=0 bash scripts/03-gpu-plugin.sh`

llama.cpp uses **`ensure_git_repo`** to preserve branch `gfx1151-rdna35-tuning` across rebuilds.

---

## Running tests

```bash
source /home/magnus/projects/venvs/amd/bin/activate
cd /home/magnus/projects/amdeai
pytest tests/build -v
pytest tests/integration -v
pytest tests/e2e -v
```

---

## Repositories (with call-flow links)

### ROCm (host stack)

**Role:** Standard GPU compute (HIP, KFD). Required for device plugin and cluster inference.

**Call flow:** [docs/call-flows/01-rocm-host.md](docs/call-flows/01-rocm-host.md)

### k3s

**Role:** Lightweight Kubernetes; registry on :32000.

**Call flow:** [docs/call-flows/02-k3s.md](docs/call-flows/02-k3s.md)

### [ROCm/k8s-device-plugin](https://github.com/ROCm/k8s-device-plugin)

**Role:** Advertises `amd.com/gpu`.

**Build:** `scripts/03-gpu-plugin.sh`  
**Call flow:** [docs/call-flows/03-k8s-device-plugin.md](docs/call-flows/03-k8s-device-plugin.md)

### Platform layer

**Deploy:** `scripts/04-platform.sh`  
**Call flow:** [docs/call-flows/04-platform.md](docs/call-flows/04-platform.md)

### [silogen/cluster-forge](https://github.com/silogen/cluster-forge)

**Build:** `scripts/05a-cluster-forge.sh`  
**Call flow:** [docs/call-flows/05a-cluster-forge.md](docs/call-flows/05a-cluster-forge.md)

### [silogen/kaiwo](https://github.com/silogen/kaiwo)

**Role:** Standard EAI workload orchestrator (KaiwoJob → HIP pods).

**Build:** `scripts/05b-kaiwo.sh`  
**Call flow:** [docs/call-flows/05b-kaiwo.md](docs/call-flows/05b-kaiwo.md)

### [amd-enterprise-ai/aim-engine](https://github.com/amd-enterprise-ai/aim-engine)

**Build:** `scripts/06a-aim-engine.sh`  
**Call flow:** [docs/call-flows/06a-aim-engine.md](docs/call-flows/06a-aim-engine.md)

### AIRM + AI Workbench

**Deploy:** `scripts/06b-airm-workbench.sh`  
**Call flow:** [docs/call-flows/06b-airm-aiwb.md](docs/call-flows/06b-airm-aiwb.md)

### [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)

**Role:** Local inference (Vulkan + HIP). Branch `gfx1151-rdna35-tuning` for Strix Halo.

**Build:** `scripts/07-llama-cpp.sh`  
**Call flow:** [docs/call-flows/07-llama-cpp.md](docs/call-flows/07-llama-cpp.md)

---

## Disk checkpoints

```bash
bash scripts/lib/disk-report.sh <label>
# log: ~/.cache/amdeai/disk-log.txt
```
