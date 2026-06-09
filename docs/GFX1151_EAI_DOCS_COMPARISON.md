# Strix Halo (gfx1151) vs AMD Enterprise AI official docs — comparison report

**Audience:** Documentation team updating AMD Enterprise AI guides for Strix Halo / gfx1151.  
**Sources compared:**

| Source | URL | Status |
|--------|-----|--------|
| AMD platform overview | [enterprise-ai.docs.amd.com/.../platform-overview.html](https://enterprise-ai.docs.amd.com/en/latest/platform-overview.html) | Valid (2026-06-06) |
| AMD on-premises install | [enterprise-ai.docs.amd.com/.../on-premises-installation.html](https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html) | Valid (2026-06-06) |
| Our call-flow overview | [CALL_FLOW_OVERVIEW.md](CALL_FLOW_OVERVIEW.md) | Local |
| gfx1151 fixes & gaps | [gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md) | Local |
| Install automation | [README.md](../README.md) | Local |

**Related AMD docs (for cross-links):**

- [AI Workbench overview](https://enterprise-ai.docs.amd.com/en/latest/workbench/overview.html)
- [Resource Manager overview](https://enterprise-ai.docs.amd.com/en/latest/resource-manager/overview.html)
- [AIMs overview](https://enterprise-ai.docs.amd.com/en/latest/aims/overview.html)
- [Login](https://enterprise-ai.docs.amd.com/en/latest/login.html)
- [ROCm on Radeon/Ryzen (gfx1151)](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/)

---

## 1. Executive summary

The [official Enterprise AI reference stack](https://enterprise-ai.docs.amd.com/en/latest/platform-overview.html) describes the **same logical architecture** we document locally (AI Workbench, Resource Manager, Kaiwo, Kubernetes, Cluster Forge, AIMs). Component names and roles **align**.

The gaps are almost entirely in **hardware scope**, **install tooling**, and **gfx1151-specific runtime requirements**:

| Area | Official docs | Our gfx1151 stack |
|------|---------------|-------------------|
| Supported GPUs | MI300X / MI325X / M350X / MI355X only | Radeon 8060S (**gfx1151**, RDNA 3.5 APU) |
| ROCm version | 7.0.2 recommended; **7.2.x not supported** | **7.2.3** installed and required for Strix Halo |
| Kubernetes installer | [Cluster Bloom](https://github.com/silogen/cluster-bloom) → **RKE2** | **Bloom → RKE2** (primary); k3s scripts remain lab alternative |
| Inference in cluster | AIMs / vLLM in GPU pods (implied Instinct) | Same path: Kaiwo → vLLM → **ROCm HIP** |
| Local host inference | Not documented | **llama.cpp** on host `:8080` (Workbench AIMModel) |
| gfx1151 tuning | Not mentioned | GRUB, env vars, llama.cpp patches, firmware notes |

**Recommendation for official docs:** Add a **“Strix Halo / gfx1151”** appendix (or link to [ROCm Radeon/Ryzen docs](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/)) covering hardware prerequisites, ROCm version, unified-memory GRUB tuning, GPU plugin env vars, and known llama.cpp MoE limitations—not a rewrite of the platform overview.

---

## 2. Platform coverage matrix (chapter-by-chapter)

Walk-through of the [AMD Enterprise AI documentation index](https://enterprise-ai.docs.amd.com/en/latest/index.html) against our **Z13 Bloom install** (2026-06-08, final validation). Status reflects phased Bloom install, GitOps workarounds, and passing UI E2E tests. See [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md) for the full fix log.

| Doc chapter | Official doc | Documented capability | Z13 install status | Automated test | Delta / notes |
|-------------|--------------|----------------------|-------------------|----------------|---------------|
| **Platform overview** | [platform-overview.html](https://enterprise-ai.docs.amd.com/en/latest/platform-overview.html) | Reference stack: Workbench, Resource Manager, Kaiwo, K8s, Cluster Forge, AIMs | **Working** — full stack up; UIs reachable via HTTPS | Integration: 4/7 pass; E2E: 3/3 pass | gfx1151 not in official hardware scope; Bloom `GPU_GFX1151` path |
| **Quick start** | (linked from index) | Fast path to running stack | **Working** — Bloom + ClusterForge bootstrap complete | E2E login PASS | Phased install: full `bloom cli`, then `--tags metallb,domain` if needed |
| **On-premises install** | [on-premises-installation.html](https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html) | Bloom → RKE2 → ROCm → Cluster Forge; `.nip.io` domain; login URLs | **Working** — RKE2 + HTTPS on `:443` + login URLs | E2E: 3/3 PASS | Z13 deltas: gfx1151 + ROCm 7.2.3 + `NO_DISKS_FOR_CLUSTER` + `INSTALL_ARGOCD: false` + GitOps patches (AIWB chart/route) |
| **Login** | [login.html](https://enterprise-ai.docs.amd.com/en/latest/login.html) | `devuser@<domain>` / Keycloak SSO between AIRM and AIWB | **Working** — Keycloak Healthy; SSO via NextAuth redirect | E2E login PASS | Playwright uses `Sign in with Keycloak` → `devuser@192.168.32.13.nip.io` |
| **AI Workbench overview** | [workbench/overview.html](https://enterprise-ai.docs.amd.com/en/latest/workbench/overview.html) | Combined mode with AIRM; AIM catalog, workspaces, fine-tune, chat | **Working** — UI pods Running; models page loads | `test_aiwb_ui` PASS (2/2) | Chart `1.1.9` + HTTPRoute parent `envoy-gateway-system` workarounds |
| **Deploy model / inference** | (workbench chapter) | Deploy AIMs, run inference via UI/CLI | **Not tested** | — | AIM Engine operator ready; no AIM deployment exercised on gfx1151 yet |
| **Fine-tune / Access models** | (workbench chapter) | HF token, model catalog | **Partial** — models page reachable | `test_models_page_gemma` PASS | HF token not configured in this validation |
| **Resource Manager overview** | [resource-manager/overview.html](https://enterprise-ai.docs.amd.com/en/latest/resource-manager/overview.html) | Clusters, orgs, projects, quotas, secrets | **Working** — `airm` Synced, Healthy | `test_airm_login` PASS | Infra (CNPG, RabbitMQ, external-secrets) healthy |
| **AIRM getting started** | (resource-manager chapter) | GPU dashboards, project management | **Partial** — login works; dashboards not exercised | E2E login only | Further UI flows not automated |
| **AIMs overview** | [aims/overview.html](https://enterprise-ai.docs.amd.com/en/latest/aims/overview.html) | Inference microservices on Instinct/Radeon Pro; OpenAI API | **Partial** — operators synced | `test_aimmodel_cr_accepted` FAIL | gfx1151 APU; AIM catalog targets Instinct profiles — runtime TBD |
| **AIMs catalog / deploy** | (aims chapter) | Pull AIM images, deploy to GPU pods | **Not tested** | — | GPU scheduling works (`amd.com/gpu` allocatable) |
| **Solution Blueprints** | [solution-blueprints/overview.html](https://enterprise-ai.docs.amd.com/en/latest/solution-blueprints/overview.html) | Helm-based reference apps (RAG, summarization, etc.) | **Not installed** | — | Not evaluated on 128 GB UMA laptop |
| **Kaiwo** | [silogen/kaiwo](https://github.com/silogen/kaiwo) (overview link) | GPU workload orchestration, queues, gang scheduling | **Working** — operator Running, node labels applied | `test_operator_ready` PASS; queue/flavor FAIL | Kueue ResourceFlavor/ClusterQueue need extra small-cluster config |
| **Kubernetes platform** | (implicit in install doc) | RKE2 via Bloom, device plugin, MetalLB | **Working** | GPU scheduling PASS | MetalLB + `cluster-tls` via Bloom `metallb,domain` tags |
| **Cluster Forge** | [silogen/cluster-forge](https://github.com/silogen/cluster-forge) | GitOps bootstrap of full stack | **Working** (with workarounds) | — | Non-empty `domain` required; AIWB chart/route patches documented |
| **Data backup / upgrade** | (platform-infrastructure chapters) | CNPG, Longhorn, MinIO backup; v2.0 upgrade | **Not evaluated** | — | `NO_DISKS_FOR_CLUSTER` — local-path not Longhorn |
| **Local host inference** | *Not in official docs* | — | **Working** — `07-llama-cpp.sh`, HIP validate | `validate-hip-gfx1151.sh` PASS | amdeai-specific path for Z13 demo |

### Test summary (2026-06-08, final)

| Suite | Result |
|-------|--------|
| `pytest tests/integration/` | **4 passed, 3 failed** (Kueue flavor/queue, AIMModel CR) |
| `scripts/validate-hip-gfx1151.sh` | **PASS** |
| `pytest tests/e2e/` (Playwright) | **3 passed** — AIWB login + models page, AIRM login via Keycloak SSO |
| Bloom `--tags metallb,domain` | **PASS** — 3 ok, 4 changed (after Ansible tag fix in cluster-bloom) |

---

## 3. Architecture alignment

### 2.1 Official platform overview

[Platform overview](https://enterprise-ai.docs.amd.com/en/latest/platform-overview.html) lists:

| Official component | Our CALL_FLOW_OVERVIEW equivalent | Match? |
|--------------------|----------------------------------|--------|
| [AMD AI Workbench](https://enterprise-ai.docs.amd.com/en/latest/workbench/overview.html) | AIWB UI/API (Layer 7) | Yes |
| [AMD Resource Manager](https://enterprise-ai.docs.amd.com/en/latest/resource-manager/overview.html) | AIRM (Layer 7, not on token hot path) | Yes |
| [Kaiwo](https://github.com/silogen/kaiwo) | Kaiwo + Kueue (Layer 5, **standard HIP path**) | Yes |
| Kubernetes platform | RKE2 via Bloom (primary); k3s scripts (lab) | Yes (Bloom matches official installer) |
| [Cluster Forge](https://github.com/silogen/cluster-forge) | `05a-cluster-forge.sh` / GitOps bootstrap | Yes |
| [AIMs](https://enterprise-ai.docs.amd.com/en/latest/aims/overview.html) | AIM Engine + AIMModel CR + optional AIM microservices | Partial — we use AIM Engine + host llama endpoint |

Official diagram: user portal + compute plane. Our [CALL_FLOW_OVERVIEW.md](CALL_FLOW_OVERVIEW.md) adds an explicit **token path** (sequence diagrams) that the overview does not provide—this is complementary, not conflicting.

### 2.2 Inference call flows

**Official (implicit):** User → Workbench → workload on Kubernetes → GPU pod → model serving (AIMs catalog / microservices on Instinct GPUs).

**Our standard path (documented):** User → AI Workbench → KaiwoJob → Kueue → k8s-device-plugin → vLLM pod → **ROCm HIP → KFD → gfx1151**.

These are the **same pattern**; we name concrete operators (Kueue, device plugin) and the HIP stack.

**Our additional local path (not in official docs):** Workbench → AIMModel CR → **host** `llama-server` (:8080) → Vulkan or HIP. This exists because:

1. Single-node Z13 demo with a registered local Gemma model.
2. [llama.cpp #21416](https://github.com/ggml-org/llama.cpp/issues/21416): Gemma 4 MoE on gfx1151 HIP — resolved via G1–G3 patches (unfused RDNA3_5 MoE path). HIP validated 2026-06-08; Vulkan available as fallback.

Official docs should state: *on gfx1151, cluster inference via Kaiwo/vLLM is the supported EAI path; optional host-side llama.cpp is a single-node pattern documented separately.*

---

## 4. Installation comparison

### 3.1 Official on-premises path

[On-premises installation](https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html):

1. Download [Cluster Bloom](https://github.com/silogen/cluster-bloom/releases/latest/download/bloom).
2. Configure `bloom.yaml` (`DOMAIN`, `CLUSTER_DISKS`, Docker Hub credentials).
3. `sudo ./bloom cli bloom.yaml` — installs **RKE2**, ROCm, Longhorn, then Cluster Forge stack (~20 min).
4. Login: `https://airmui.<IP>.nip.io`, `https://aiwbui.<IP>.nip.io`.
5. HF token via Workbench UI secrets.

**Alternative paths in same doc:**

- Manual Cluster Forge after Bloom with `CLUSTERFORGE_RELEASE: "none"`.
- Existing cluster: Cluster Forge `bootstrap.sh` only ([v2.1.0 tarball](https://github.com/silogen/cluster-forge/releases/download/v2.1.0/release-enterprise-ai-v2.1.0.tar.gz)).

### 3.2 Our gfx1151 path

**Primary:** [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md) — `sudo ./bloom cli bloom-gfx1151.yaml` on **Asus Z13 / gfx1151** (validated 2026-06-08).

**Alternative:** [README.md](../README.md) — scripted **k3s** pipeline on the same hardware:

| Step | Script | Bloom equivalent (`GPU_GFX1151: true`) |
|------|--------|----------------------------------------|
| Prerequisites | `00-prerequisites.sh` | Bloom `validate_node` (partial) |
| ROCm + GRUB | `01-host-rocm.sh` | `gpu_rocm_gfx1151.yaml` + `gpu_grub_gfx1151.yaml` + `gpu_env_gfx1151.yaml` |
| Kubernetes | `02-kubernetes.sh` (**k3s**, registry :32000) | Bloom RKE2 install |
| GPU plugin | `03-gpu-plugin.sh` + **gfx1151 env** | `gpu_device_plugin_gfx1151.yaml` |
| Platform | `04-platform.sh` | Bloom `deploy_k8s_apps` + Cluster Forge bundle |
| Cluster Forge | `05a-cluster-forge.sh` | `deploy_clusterforge` / `bootstrap.sh` |
| Kaiwo | `05b-kaiwo.sh` | Part of Cluster Forge stack + Kaiwo labels in Bloom |
| AIM Engine | `06a-aim-engine.sh` | Part of Cluster Forge stack |
| AIRM + AIWB | `06b-airm-workbench.sh` | Part of Cluster Forge stack |
| Local llama | `07-llama-cpp.sh` | **Not in Bloom** — run script after Bloom install |

**Key install differences to document for gfx1151:**

| Topic | Official | Strix Halo addendum |
|-------|----------|-------------------|
| Installer | Cluster Bloom (required in doc) | **Bloom + `GPU_GFX1151: true`** ([BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md)); k3s scripts as lab alternative |
| Min CPU | 20 cores | Z13 meets this |
| Disk | 500 GB+ root, 3 TB+ data, **raw NVMe** | Laptop: often single NVMe; Longhorn may use loop/hostPath |
| GPU | Instinct only | gfx1151 integrated; **1 GPU**, unified memory |
| Domain | `.nip.io` supported | Same pattern: `<node-ip>.nip.io` |
| ROCm | 7.0.2; 7.2.x unsupported | **7.2.x + Radeon/Ryzen stream** — doc contradiction must be resolved |

---

## 5. System requirements — critical differences

### 4.1 Hardware (official vs gfx1151)

From [on-premises installation — System requirements](https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html#system-requirements):

> AMD MI300X, MI325X, M350X or MI355X GPUs

**Strix Halo is not listed.** For gfx1151 documentation add:

| Property | Instinct (official) | Strix Halo (gfx1151) |
|----------|---------------------|----------------------|
| Product | MI300X series | Ryzen AI Max+ / Radeon 8060S |
| ISA | CDNA | **gfx1151** (RDNA 3.5) |
| Memory | HBM per GPU | **Unified LPDDR5x** (~128 GB) |
| GPU count | Multi-GPU clusters | Typically **1** iGPU |
| Topology | Multi-node | Single-node demo |

### 4.2 ROCm version

Official: **ROCm 7.0.2 recommended; 7.2.x currently not supported.**

Our stack: **ROCm 7.2.3** with gfx1151 detected via `rocminfo`. AMD’s consumer APU path is documented under [ROCm Radeon/Ryzen](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/), not the Instinct on-prem page.

**Documentation action:** Split requirements:

- **Instinct on-prem:** keep 7.0.2 guidance.
- **Strix Halo / gfx1151:** link to Radeon/Ryzen install guide; specify supported 7.x line and kernel/firmware minimums.

### 4.3 Unified memory (gfx1151 only)

Not in official EAI docs. Required for Strix Halo ([gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md)):

```text
# GRUB (example)
amdgpu.gttsize=131072
ttm.pages_limit=33554432
amd_iommu=off

# /etc/environment
HSA_OVERRIDE_GFX_VERSION=11.5.1
```

Verify after reboot: `rocm-smi --showmeminfo vram` → ~128 GiB, not ~4 GiB.

---

## 6. Runtime / env vars (gfx1151 only)

Official on-prem doc: generic “ROCm will be installed” when `GPU_NODE: true`. **No gfx1151 env vars.**

Our [03-gpu-plugin.sh](../scripts/03-gpu-plugin.sh) and [01-rocm-host.md](call-flows/01-rocm-host.md) inject:

| Variable | Purpose | Reference |
|----------|---------|-----------|
| `HSA_OVERRIDE_GFX_VERSION=11.5.1` | Correct ISA on Strix Halo | [ROCm env vars](https://rocm.docs.amd.com/en/reference/env-variables.html) |
| `HSA_ENABLE_SDMA=0` | Avoid PERMISSION_FAULT on UMA | [ROCm#6186](https://github.com/ROCm/ROCm/issues/6186) |
| `MIOPEN_FIND_ENFORCE=1` | MIOpen CK lockup workaround | [TheRock#5259](https://github.com/ROCm/TheRock/issues/5259) |
| `PYTORCH_TUNABLEOP_ENABLED=1` | GEMM autotune | Local practice |
| `TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` | Experimental attention | [TheRock gfx1151 wheels](https://rocm.nightlies.amd.com/v2/gfx1151/) |

**Documentation action:** Add a table “Recommended environment variables for gfx1151 GPU pods” to the on-prem or Radeon/Ryzen appendix.

---

## 7. Bug fixes and upstream work (our analysis)

Documented in [gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md). Summary for EAI doc team:

| ID | Issue | Layer | Official doc today | Suggested doc note |
|----|-------|-------|--------------------|--------------------|
| G1–G3 | llama.cpp RDNA3.5 MMVQ/MMQ; MoE fusion | Host llama.cpp HIP | Not covered | “Host llama.cpp HIP on gfx1151: use patched build (G1–G3). **HIP validated 2026-06-08** for Gemma 4 + SLMs; Vulkan available as fallback.” |
| G4 | HIP PERMISSION_FAULT | ROCm / UMA | Not covered | `HSA_ENABLE_SDMA=0` |
| G5 | MIOpen CK lockup | vLLM/PyTorch pods | Not covered | `MIOPEN_FIND_ENFORCE=1` |
| G6 | MES 0x83 firmware hang | linux-firmware | Not covered | Link [ROCm#5724](https://github.com/ROCm/ROCm/issues/5724) |
| G7 | KFD ABI ≥1.20 | Kernel | Not covered | Kernel ≥6.17 |
| G8 | AOTriton experimental | PyTorch | Not covered | TheRock nightlies for gfx1151 |

**Gemma 4 MoE:** [llama.cpp #21416](https://github.com/ggml-org/llama.cpp/issues/21416) — HIP produced `<unused24>` token loop; **resolved** via G1–G3 patches (unfused MoE on RDNA3_5, merged to llama.cpp `master` @ `0ab06d382`). **HIP validated 2026-06-08**: Gemma 4 26B-A4B — 114 t/s prompt, 36 t/s gen, no router corruption. HIP is now the default backend; Vulkan available as `EAI_LLAMA_BACKEND=vulkan`.

---

## 8. Component-by-component checklist for doc updates

Use this when adding a **Strix Halo (gfx1151) on-premises guide**:

### 7.1 Prerequisites page

- [x] Local gfx1151 install path documented — [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md) (upstream AMD docs still pending).
- [ ] Add gfx1151 / Radeon 8060S / Ryzen AI Max+ to supported hardware table (separate from Instinct).
- [ ] Link [ROCm Radeon/Ryzen install](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/).
- [ ] Resolve ROCm 7.0.2 vs 7.2.x wording (Instinct vs APU).
- [ ] Document GRUB + reboot for unified memory.
- [ ] Note single-GPU / single-node limits vs MI300X multi-GPU.

### 7.2 Installation page

- [x] Cluster Bloom supports gfx1151 via `GPU_GFX1151: true` — see [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md) and `bloom-gfx1151.yaml`.
- [x] Document k3s as a **community/lab** alternative (see [README.md](../README.md) “Alternative — k3s script pipeline”).
- [ ] Add Docker Hub credentials (already in official doc — keep).
- [ ] Add `HF_TOKEN` / Workbench secrets (already in official doc — keep).

### 7.3 Platform overview / call flows

- [ ] Add one diagram: Workbench → Kaiwo → GPU pod → HIP (same as our “Standard path” in [CALL_FLOW_OVERVIEW.md](CALL_FLOW_OVERVIEW.md)).
- [ ] Optional: footnote for single-node host llama + AIMModel pattern.

### 7.4 GPU operator / device plugin

- [ ] Document `amd.com/gpu` + gfx1151 env vars for DaemonSet.
- [ ] Kaiwo `ResourceFlavor` example for `amd-gfx1151` (1 GPU quota).

### 7.5 Inference / AIMs

- [ ] State cluster vLLM/PyTorch via Kaiwo is the **primary** gfx1151 inference path in EAI.
- [ ] Note AOTriton/TheRock may be needed for latest PyTorch on gfx1151.

### 7.6 Validation

- [ ] Point to `scripts/validate-hip-gfx1151.sh` (or equivalent) in lab docs: SLM + Gemma 4 MoE HIP test.

---

## 9. Suggested new doc section (copy-paste starter)

**Title:** *On-premises installation on Strix Halo (gfx1151)*  
**Placement:** Sub-page under [On-premises installation](https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html) or cross-link from [ROCm Radeon/Ryzen](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/).

```markdown
### Supported hardware
- Ryzen AI Max+ / Radeon 8060S (gfx1151, RDNA 3.5)
- 128 GB unified memory recommended for large models
- Not interchangeable with MI300X Instinct requirements on the main install page

### Before Cluster Forge / Bloom
1. Install ROCm per Radeon/Ryzen guide (not Instinct 7.0.2-only path).
2. Apply GRUB: amdgpu.gttsize, ttm.pages_limit, amd_iommu=off; reboot.
3. Set HSA_OVERRIDE_GFX_VERSION=11.5.1.
4. Verify: rocminfo | grep gfx1151; rocm-smi --showmeminfo vram ≈ system RAM.

### GPU device plugin
Set in AMD GPU DaemonSet env: HSA_OVERRIDE_GFX_VERSION, HSA_ENABLE_SDMA=0,
MIOPEN_FIND_ENFORCE=1 (see troubleshooting links).

### Inference
- Standard: submit jobs via AI Workbench → Kaiwo → vLLM (ROCm HIP in pod).
- Single-node lab: optional host llama-server + AIMModel; Gemma 4 MoE may require
  Vulkan or patched llama.cpp HIP (see llama.cpp issue #21416).

### Install path
Use Cluster Bloom with `GPU_GFX1151: true` and [bloom-gfx1151.yaml](../bloom-gfx1151.yaml).
See [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md). k3s scripts remain a lab alternative.
```

---

## 10. URL validation log (2026-06-06)

| URL | Result |
|-----|--------|
| https://enterprise-ai.docs.amd.com/en/latest/platform-overview.html | OK |
| https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html | OK |
| https://enterprise-ai.docs.amd.com/en/latest/workbench/overview.html | Referenced from install page |
| https://enterprise-ai.docs.amd.com/en/latest/resource-manager/overview.html | Referenced from platform overview |
| https://enterprise-ai.docs.amd.com/en/latest/aims/overview.html | Referenced from platform overview |
| https://enterprise-ai.docs.amd.com/en/latest/login.html | Referenced from install page |
| https://github.com/silogen/cluster-bloom | Referenced from install page |
| https://github.com/silogen/cluster-forge | Referenced from install page |
| https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/ | AMD gfx1151 ROCm path (external to EAI doc tree) |

---

## 11. Local references (amdeai repo)

| Document | Purpose |
|----------|---------|
| [CALL_FLOW_OVERVIEW.md](CALL_FLOW_OVERVIEW.md) | Token paths: standard HIP + local llama |
| [gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md) | Patches G1–G8, upstream PR targets |
| [BLOOM_GFX1151_INSTALL.md](BLOOM_GFX1151_INSTALL.md) | Cluster Bloom gfx1151 install guide |
| [bloom-gfx1151.yaml](../bloom-gfx1151.yaml) | Reference Bloom config for Z13 |
| [README.md](../README.md) | Bloom quick start + k3s script alternative |
| [call-flows/](call-flows/) | Per-component call flows |
| `scripts/validate-hip-gfx1151.sh` | Post-install HIP validation |

**Branches:** `amdeai` → `gfx1151-rocm-enable`; `llama.cpp` → `master` @ `0ab06d382` (gfx1151 patches merged).
