# AMD Enterprise AI Suite — Z13 (amdeai)

Automation and tests for building the [AMD Enterprise AI Suite](eai-suite-z13-guide.md) on Asus Z13 (Radeon 8060S, gfx1151, 128 GB RAM, Ubuntu 24.04).

**Python venv (required for tests):** `/home/magnus/projects/venvs/amd`

```bash
source /home/magnus/projects/venvs/amd/bin/activate
pip install -r tests/requirements.txt
playwright install chromium
```

**Build tree:** `~/eai-build/` (cloned repositories)

**Scripts:** `scripts/00-prerequisites.sh` … `scripts/07-llama-cpp.sh`

**Disk checkpoints:** `scripts/lib/disk-report.sh <label>` after each layer (log in `~/.cache/amdeai/disk-log.txt`).

### Force rebuild (default)

Every script sets **`EAI_FORCE_REBUILD=1`** by default: fresh git clones, `--no-cache` Docker builds, Helm uninstall/reinstall, ROCm reinstall, k3s reinstall, and clean CMake trees. This is intentional so you can read sources under `~/eai-build/` and surface build/runtime bugs.

To allow skips (not recommended): `EAI_FORCE_REBUILD=0 bash scripts/03-gpu-plugin.sh`

Full stack: `bash scripts/run-all.sh` (requires sudo; set `HF_TOKEN` before layer 06b).

### Call flows (prompt → kernel → response)

- **[End-to-end overview](docs/CALL_FLOW_OVERVIEW.md)** — sequence from AI Workbench chat through llama.cpp Vulkan to gfx1151 and back.
- Per-component docs in **[docs/call-flows/](docs/call-flows/)** — linked from each repository chapter below.

---

## Host environment notes

Your system already has kernel cmdline tuning (see `01-host-rocm.sh`):

| Parameter | Your value | Guide value |
|-----------|------------|-------------|
| `amdgpu.gttsize` | 110000 | 131072 |
| `ttm.pages_limit` | 12582912 | 33554432 |
| `amd_iommu` | *(missing)* | off |
| `amdgpu.dcdebugmask` | 0x10 | — |

ROCm 7.2.1 is installed; `gfx1151` is detected. If `rocm-smi` still reports ~4 GiB VRAM, apply `HSA_OVERRIDE_GFX_VERSION=11.5.1` and consider aligning GRUB with the guide (`EAI_GRUB_APPLY_GUIDE_VALUES=1`).

---

## Repositories

### ROCm (host stack)

**Role:** AMD GPU compute stack (HIP, rocBLAS, rocminfo, rocm-smi). Required for device-plugin builds and ROCm workloads.

**Call flow:** [docs/call-flows/01-rocm-host.md](docs/call-flows/01-rocm-host.md) — GRUB memory pool, `amdgpu` kernel, HSA overrides; substrate for HIP pods; DRM path for Vulkan.

**Docs:**

- [ROCm documentation](https://rocm.docs.amd.com/)
- [Install on Linux](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/)
- [ROCm on Radeon and Ryzen](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/index.html)
- [Environment variables](https://rocm.docs.amd.com/en/reference/env-variables.html)

---

### k3s

**Role:** Lightweight single-node Kubernetes cluster; base for registry, operators, and Helm releases.

**Call flow:** [docs/call-flows/02-k3s.md](docs/call-flows/02-k3s.md) — API server → controllers → kubelet → pod network for UI/operators.

**Docs:**

- [K3s documentation](https://docs.k3s.io/)
- [Installation](https://docs.k3s.io/installation)
- [Registries configuration](https://docs.k3s.io/installation/private-registry)

---

### [ROCm/k8s-device-plugin](https://github.com/ROCm/k8s-device-plugin)

**Role:** Kubernetes device plugin that advertises `amd.com/gpu` on nodes so GPU workloads can be scheduled.

**Docs:**

- [Repository README](https://github.com/ROCm/k8s-device-plugin/blob/master/README.md)
- [ROCm Kubernetes documentation](https://rocm.docs.amd.com/projects/k8s-device-plugin/en/latest/)

**Build:** `scripts/03-gpu-plugin.sh` — Docker image → `localhost:32000/amd-gpu-device-plugin:latest`

**Call flow:** [docs/call-flows/03-k8s-device-plugin.md](docs/call-flows/03-k8s-device-plugin.md) — kubelet gRPC → `amd.com/gpu` → GPU pods (not host Vulkan llama).

---

### Platform layer (cert-manager, MetalLB, Longhorn, Gateway API, Kueue, KubeRay, KServe)

**Role:** TLS, load balancing, storage, routing, queuing, Ray, and KServe serving infrastructure.

**Call flow:** [docs/call-flows/04-platform.md](docs/call-flows/04-platform.md) — how each chart participates (or not) in the chat path.

**Docs (cert-manager example):**

- [cert-manager documentation](https://cert-manager.io/docs/)
- [MetalLB documentation](https://metallb.io/)
- [Longhorn documentation](https://longhorn.io/docs/)
- [Gateway API documentation](https://gateway-api.sigs.k8s.io/)
- [Kueue documentation](https://kueue.sigs.k8s.io/docs/overview/)
- [KubeRay documentation](https://ray-project.github.io/kuberay/)
- [KServe documentation](https://kserve.github.io/website/)

**Deploy:** `scripts/04-platform.sh` (Helm; force reinstall)

---

### [silogen/cluster-forge](https://github.com/silogen/cluster-forge)

**Role:** Go tool that bundles Helm charts and YAML into a GitOps deployable stack (ArgoCD, Gitea, Keycloak, MinIO, Kaiwo, etc.).

**Docs:**

- [Repository](https://github.com/silogen/cluster-forge)
- [ArgoCD documentation](https://argo-cd.readthedocs.io/) *(deployed by cluster-forge)*

**Build:** `scripts/05a-cluster-forge.sh`

**Call flow:** [docs/call-flows/05a-cluster-forge.md](docs/call-flows/05a-cluster-forge.md) — smelt/cast/bootstrap only; not in token hot path.

---

### [silogen/kaiwo](https://github.com/silogen/kaiwo)

**Role:** AI workload orchestrator for Kubernetes; topology-aware scheduling and integration with Kueue.

**Docs:**

- [Repository](https://github.com/silogen/kaiwo)
- [Kueue documentation](https://kueue.sigs.k8s.io/docs/overview/) *(resource flavors)*

**Build:** `scripts/05b-kaiwo.sh`

**Call flow:** [docs/call-flows/05b-kaiwo.md](docs/call-flows/05b-kaiwo.md) — KaiwoJob → Kueue → GPU pod (cluster inference path).

---

### [amd-enterprise-ai/aim-engine](https://github.com/amd-enterprise-ai/aim-engine)

**Role:** Kubernetes operator for AMD inference deployments (`AIMModel` CRDs, Helm chart, routing).

**Docs:**

- [Repository](https://github.com/amd-enterprise-ai/aim-engine)

**Build:** `scripts/06a-aim-engine.sh`

**Call flow:** [docs/call-flows/06a-aim-engine.md](docs/call-flows/06a-aim-engine.md) — AIMModel CR registration and routing config.

---

### AMD Resource Manager (AIRM)

**Role:** Pre-built Helm chart for GPU/resource management UI and APIs (not built from source).

**Docs:**

- Chart: `oci://docker.io/amdenterpriseai/charts/airm` (see [eai-suite-z13-guide.md](eai-suite-z13-guide.md))

**Deploy:** `scripts/06b-airm-workbench.sh`

**Call flow:** [docs/call-flows/06b-airm-aiwb.md](docs/call-flows/06b-airm-aiwb.md) — UI/SSO at top of stack; resolves AIMModel → llama endpoint.

---

### AMD AI Workbench (AIWB)

**Role:** Pre-built Helm chart for model catalog, chat UI, and Hugging Face integration.

**Docs:**

- Chart: `oci://docker.io/amdenterpriseai/charts/aiwb` (see [eai-suite-z13-guide.md](eai-suite-z13-guide.md))

**Deploy:** `scripts/06b-airm-workbench.sh` — UI at `https://aiwbui.<DOMAIN>`

**E2E:** Playwright tests in `tests/e2e/test_aiwb_ui.py`

---

### [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)

**Role:** LLM inference; **Vulkan backend required** for Gemma 4 on gfx1151 (HIP/ROCm loop bug). Serves OpenAI-compatible API on port 8080.

**Docs:**

- [Repository](https://github.com/ggml-org/llama.cpp)
- [Build documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md)
- [llama-server](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [Vulkan backend](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md#vulkan)

**Build:** `scripts/07-llama-cpp.sh`

**Call flow:** [docs/call-flows/07-llama-cpp.md](docs/call-flows/07-llama-cpp.md) — **primary token path:** HTTP → GGML → Vulkan → `amdgpu` → gfx1151.

---

## Running tests

```bash
source /home/magnus/projects/venvs/amd/bin/activate
cd /home/magnus/projects/amdeai
pytest tests/build -v          # after each repo build
pytest tests/integration -v  # after k8s operators are up
pytest tests/e2e -v          # requires UIs + port-forwards
```

## Script order

```bash
bash scripts/lib/disk-report.sh baseline --baseline
bash scripts/00-prerequisites.sh
bash scripts/01-host-rocm.sh    # may require reboot
bash scripts/02-kubernetes.sh
bash scripts/03-gpu-plugin.sh
bash scripts/04-platform.sh
bash scripts/05a-cluster-forge.sh
bash scripts/05b-kaiwo.sh
bash scripts/06a-aim-engine.sh
bash scripts/06b-airm-workbench.sh   # needs HF_TOKEN
bash scripts/07-llama-cpp.sh
```
