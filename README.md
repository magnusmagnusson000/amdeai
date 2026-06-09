# AMD Enterprise AI Suite — Z13 (amdeai)

Automation, documentation, and tests for the [AMD Enterprise AI Suite](docs/OVERVIEW.md) on Asus Z13 (Radeon 8060S, **gfx1151**, 128 GB RAM, Ubuntu 24.04).

**Standard inference path:** ROCm HIP in Kubernetes (Kaiwo → vLLM → gfx1151)  
**Local Workbench chat:** llama.cpp on host port 8080 (HIP validated 2026-06-08; Vulkan as fallback)  
**gfx1151 patches:** [docs/gfx1151-upstream-pr-guide.md](docs/gfx1151-upstream-pr-guide.md)

---

## Quick start — Cluster Bloom (official path)

Single-command install via [Cluster Bloom](https://github.com/silogen/cluster-bloom) + RKE2. Equivalent to scripts `01`–`06b` for gfx1151.

```bash
cd /home/magnus/projects/amdeai
wget -O bloom https://github.com/silogen/cluster-bloom/releases/latest/download/bloom
chmod +x bloom
NODE_IP=$(hostname -I | awk '{print $1}')
sed -i "s|^DOMAIN:.*|DOMAIN: \"${NODE_IP}.nip.io\"|" bloom-gfx1151.yaml
sudo ./bloom cli bloom-gfx1151.yaml
# Reboot if Bloom reports GRUB/env changes, then re-run bloom
```

**Guide:** [docs/BLOOM_GFX1151_INSTALL.md](docs/BLOOM_GFX1151_INSTALL.md)  
**Config:** [bloom-gfx1151.yaml](bloom-gfx1151.yaml) (`GPU_GFX1151: true`)

Optional after Bloom: `bash scripts/07-llama-cpp.sh` for local Workbench chat via host `llama-server`.

**Login:** AIWB and AIRM use `devuser@<IP>.nip.io` via Keycloak SSO. See [Retrieve credentials](docs/BLOOM_GFX1151_INSTALL.md#retrieve-credentials) for password commands.

---

## Alternative — k3s script pipeline (lab / debug)

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

| Service | URL | Username |
|---------|-----|----------|
| AI Workbench | `https://aiwbui.<IP>.nip.io` | `devuser@<IP>.nip.io` |
| AIRM | `https://airmui.<IP>.nip.io` | `devuser@<IP>.nip.io` |
| Keycloak admin | `https://kc.<IP>.nip.io` | `silogen-admin` |

**Passwords** — secrets are base64-encoded; `kubectl get secret` alone does not show values:

```bash
# DevUser (AIWB + AIRM) — click "Sign in with Keycloak" in the UI
kubectl -n keycloak get secret airm-realm-credentials \
  -o jsonpath='{.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}' | base64 --decode && echo

# Keycloak admin
kubectl -n keycloak get secret keycloak-credentials \
  -o jsonpath='{.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}' | base64 --decode && echo
```

Full credential reference: [docs/BLOOM_GFX1151_INSTALL.md — Retrieve credentials](docs/BLOOM_GFX1151_INSTALL.md#retrieve-credentials).

### Step 7 — llama.cpp (`07-llama-cpp.sh`)

Builds llama.cpp from `~/eai-build/llama.cpp` (branch **`gfx1151-rdna35-tuning`**), starts systemd user service, registers AIMModel.

```bash
# Default: HIP backend (validated 2026-06-08 — Gemma 4 + SLMs)
bash scripts/07-llama-cpp.sh

# Force Vulkan fallback (Mesa RADV, no ROCm dependency)
EAI_LLAMA_BACKEND=vulkan bash scripts/07-llama-cpp.sh

# Skip HIP binary build (Vulkan-only install)
EAI_LLAMA_BUILD_HIP=0 EAI_LLAMA_BACKEND=vulkan bash scripts/07-llama-cpp.sh
```

Place Gemma GGUF at `~/models/gemma-4-26b-a4b-it-Q4_K_M.gguf` or set `MODEL_PATH=...`.

**Local server:** `http://<node-ip>:8080` (OpenAI-compatible, no auth).

---

## gfx1151 / ROCm notes

| Topic | Action |
|-------|--------|
| **`amdgpu-dkms` must NOT be installed** | Causes HIP PERMISSION_FAULT page faults on gfx1151; see [G9 in upstream guide](docs/gfx1151-upstream-pr-guide.md#fix-g9--remove-amdgpu-dkms-use-in-tree-amdgpu-from-oem-kernel) |
| **Use `linux-oem-24.04d` kernel** | Supplies in-tree `amdgpu` with MES 0x80; `scripts/01-host-rocm.sh` installs it automatically |
| HIP kernel fixes | Branch `gfx1151-rdna35-tuning` in `~/eai-build/llama.cpp` |
| Upstream PR guide | [docs/gfx1151-upstream-pr-guide.md](docs/gfx1151-upstream-pr-guide.md) |
| Gemma 4 on HIP | **Validated PASS** (2026-06-08) — 114 t/s prompt, 36 t/s gen, no router corruption |
| SLM test model | Phi-4-mini Q4_K_M (Qwen3.5 architecture hangs at graph-reserve on gfx1151) |
| Firmware MES | Must be `0x80`; `0x83` causes hangs — `amdgpu.cwsr_enable=0` is a fallback workaround |
| Sync repos | `bash scripts/sync-eai-build.sh` |

**GRUB parameters (set by `scripts/01-host-rocm.sh`):**

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `amdgpu.gttsize=131072` | 128 GiB MiB | Expose full unified memory pool to GPU |
| `ttm.pages_limit=33554432` | 128 GiB in pages | TTM budget for GPU BOs |
| `amd_iommu=off` | off | Prevent IOMMU from blocking UMA DMA |
| `amdgpu.cwsr_enable=0` | 0 | Workaround for MES 0x83 hang; safe on 0x80 too |

> **`rocm-smi` VRAM note:** on Strix Halo `rocm-smi --showmeminfo vram` always reports ~4 GiB — that is the `vis_vram` carve-out. The GPU-accessible memory is the GTT pool (~128 GiB) shown by `llama-cli --list-devices` and `cat /sys/class/drm/card1/device/mem_info_gtt_total`. This is normal and not an error.

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

### [silogen/cluster-bloom](https://github.com/silogen/cluster-bloom)

**Role:** Official RKE2 + ROCm + Cluster Forge installer (primary gfx1151 path).

**Config:** [bloom-gfx1151.yaml](bloom-gfx1151.yaml)  
**Call flow:** [docs/call-flows/08-bloom.md](docs/call-flows/08-bloom.md)

### k3s

**Role:** Lightweight Kubernetes (alternative lab path); registry on :32000.

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
**Deep-dive:** [docs/AIM_ENGINE_DEEP_DIVE.md](docs/AIM_ENGINE_DEEP_DIVE.md)

#### Gemma 4 31B (local GGUF + AIMModel on gfx1151)

Uses existing GGUF weights only — no Hugging Face download:

```bash
EAI_LLAMA_BACKEND=hip bash scripts/08-gemma4-31b.sh
```

See [docs/call-flows/08-gemma4-31b.md](docs/call-flows/08-gemma4-31b.md) and [docs/AIM_ENGINE_DEEP_DIVE.md](docs/AIM_ENGINE_DEEP_DIVE.md) §11.

#### Register a local host endpoint (AIMModel pattern)

AIM Engine v0.2.x removed `spec.endpoint` on `AIMModel`. For ad-hoc host registration without a managed `AIMService`, use Service + Endpoints + catalog stub — see [docs/AIM_ENGINE_DEEP_DIVE.md](docs/AIM_ENGINE_DEEP_DIVE.md) §8.4.

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
