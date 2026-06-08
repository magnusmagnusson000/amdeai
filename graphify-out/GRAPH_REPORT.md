# Graph Report - amdeai  (2026-06-08)

## Corpus Check
- 51 files · ~31,321 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 528 nodes · 542 edges · 52 communities (45 shown, 7 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 6 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `a615bf3a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]
- [[_COMMUNITY_Community 38|Community 38]]
- [[_COMMUNITY_Community 39|Community 39]]
- [[_COMMUNITY_Community 40|Community 40]]
- [[_COMMUNITY_Community 41|Community 41]]
- [[_COMMUNITY_Community 42|Community 42]]
- [[_COMMUNITY_Community 43|Community 43]]
- [[_COMMUNITY_Community 44|Community 44]]
- [[_COMMUNITY_Community 45|Community 45]]
- [[_COMMUNITY_Community 46|Community 46]]
- [[_COMMUNITY_Community 47|Community 47]]
- [[_COMMUNITY_Community 48|Community 48]]
- [[_COMMUNITY_Community 49|Community 49]]
- [[_COMMUNITY_Community 50|Community 50]]
- [[_COMMUNITY_Community 51|Community 51]]

## God Nodes (most connected - your core abstractions)
1. `AMD Enterprise AI Suite — Stack Overview` - 16 edges
2. `AIM Engine — Deep Dive` - 15 edges
3. `AMD Enterprise AI Suite — Build From Source Guide` - 15 edges
4. `On-premises installation on Strix Halo (gfx1151) via Cluster Bloom` - 14 edges
5. `Strix Halo (gfx1151) vs AMD Enterprise AI official docs — comparison report` - 12 edges
6. `gfx1151 (Strix Halo) — upstream contribution guide` - 12 edges
7. `setup_k3d_cluster()` - 11 edges
8. `AMD Enterprise AI Suite — Z13 (amdeai)` - 11 edges
9. `Step-by-step guide` - 11 edges
10. `Repositories (with call-flow links)` - 11 edges

## Surprising Connections (you probably didn't know these)
- `AMD Enterprise AI Suite — Z13 (amdeai)` --references--> `AMD Enterprise AI Suite — Build From Source Guide`  [EXTRACTED]
  README.md → eai-suite-z13-guide.md
- `AMD Enterprise AI Suite — Stack Overview` --conceptually_related_to--> `Call flow: prerequisites (build toolchain)`  [INFERRED]
  docs/OVERVIEW.md → docs/call-flows/00-prerequisites.md
- `AMD Enterprise AI Suite — Stack Overview` --conceptually_related_to--> `Call flow: ROCm + host kernel (memory and compute substrate)`  [INFERRED]
  docs/OVERVIEW.md → docs/call-flows/01-rocm-host.md
- `AMD Enterprise AI Suite — Stack Overview` --conceptually_related_to--> `Call flow: k3s (Kubernetes runtime)`  [INFERRED]
  docs/OVERVIEW.md → docs/call-flows/02-k3s.md
- `AMD Enterprise AI Suite — Stack Overview` --conceptually_related_to--> `Call flow: ROCm/k8s-device-plugin`  [INFERRED]
  docs/OVERVIEW.md → docs/call-flows/03-k8s-device-plugin.md

## Import Cycles
- None detected.

## Communities (52 total, 7 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.23
Nodes (17): 02-kubernetes.sh script, apply_registry_manifest(), backup_kubeconfig(), check_registry_nodeport_free(), configure_k3s_registries(), disable_swap_for_kubernetes(), install_k3d_local(), k3s_cluster_healthy() (+9 more)

### Community 1 - "Community 1"
Cohesion: 0.15
Nodes (6): common.sh script, disk-report.sh script, EAI_FORCE_REBUILD, PATH, root_used_bytes(), snapshot()

### Community 2 - "Community 2"
Cohesion: 0.22
Nodes (10): bool, Path, domain(), eai_build(), k8s_available(), my_ip(), Path, str (+2 more)

### Community 3 - "Community 3"
Cohesion: 0.31
Nodes (9): force-build.sh script, eai_force_enabled(), ensure_git_repo(), force_apt_reinstall(), force_docker_build(), force_helm_reinstall(), force_k3s_reinstall(), force_remove_cmake_build() (+1 more)

### Community 4 - "Community 4"
Cohesion: 0.29
Nodes (10): Browser, BrowserContext, airm_password(), argocd_password(), browser_context(), devuser_password(), keycloak_password(), page() (+2 more)

### Community 5 - "Community 5"
Cohesion: 0.25
Nodes (8): End-to-end call flow: chat prompt → hardware → response, Call flow: prerequisites (build toolchain), Call flow: ROCm + host kernel (memory and compute substrate), Call flow: k3s (Kubernetes runtime), Call flow: ROCm/k8s-device-plugin, Call flow: Layer 4 platform (Helm charts), Call flow: silogen/cluster-forge, AMD Enterprise AI Suite — Stack Overview

### Community 6 - "Community 6"
Cohesion: 0.22
Nodes (3): Integration: AIM Engine operator and AIMModel CR., Integration: Kaiwo operator and Kueue resources., test_operator_ready()

### Community 7 - "Community 7"
Cohesion: 0.57
Nodes (6): _keycloak_login(), E2E: AMD AI Workbench UI., test_keycloak_login(), test_models_page_gemma(), Page, str

### Community 8 - "Community 8"
Cohesion: 0.47
Nodes (5): E2E: Argo CD UI (requires port-forward to localhost:8443)., test_applications_visible(), test_login(), Page, str

### Community 9 - "Community 9"
Cohesion: 0.33
Nodes (4): 01-host-rocm.sh script, EAI_GRUB_GUIDE_GTT, EAI_GRUB_GUIDE_TTM, PATH

### Community 10 - "Community 10"
Cohesion: 0.33
Nodes (5): graphify-all.sh script, GRAPHIFY_OLLAMA_KEEP_ALIVE, GRAPHIFY_OLLAMA_NUM_CTX, OLLAMA_API_KEY, PYTHONUNBUFFERED

### Community 11 - "Community 11"
Cohesion: 0.40
Nodes (5): run-all.sh script, EAI_FORCE_REBUILD, EAI_GRUB_APPLY_GUIDE_VALUES, EAI_MIN_FREE_GB, run_step()

### Community 12 - "Community 12"
Cohesion: 0.40
Nodes (5): Call flow: silogen/kaiwo, Call flow: amd-enterprise-ai/aim-engine, Call flow: AMD AI Workbench + AIRM (UI and control plane), Call flow: ggml-org/llama.cpp (inference hot path), requirements.txt for tests

### Community 13 - "Community 13"
Cohesion: 0.40
Nodes (4): E2E: AMD Resource Manager UI., test_airm_login(), Page, str

### Community 14 - "Community 14"
Cohesion: 0.38
Nodes (6): 07-llama-cpp.sh script, build_hip(), build_vulkan(), KUBECONFIG, MY_IP, PATH

### Community 15 - "Community 15"
Cohesion: 0.33
Nodes (5): 05a-cluster-forge.sh script, DOMAIN, KUBECONFIG, MY_IP, PATH

### Community 16 - "Community 16"
Cohesion: 0.50
Nodes (3): 04-platform.sh script, KUBECONFIG, MY_IP

### Community 17 - "Community 17"
Cohesion: 0.50
Nodes (3): 05b-kaiwo.sh script, KUBECONFIG, PATH

### Community 19 - "Community 19"
Cohesion: 0.70
Nodes (4): fetch-study-sources.sh script, clone_depth1(), create_private_stub(), pull_oci_chart()

### Community 23 - "Community 23"
Cohesion: 0.50
Nodes (3): 06b-airm-workbench.sh script, DOMAIN, KUBECONFIG

### Community 24 - "Community 24"
Cohesion: 0.29
Nodes (6): markdownMermaidZoom.controls.show, markdownMermaidZoom.darkModeTheme, markdownMermaidZoom.fullscreen, markdownMermaidZoom.lightModeTheme, python.defaultInterpreterPath, python.terminal.activateEnvironment

### Community 27 - "Community 27"
Cohesion: 0.04
Nodes (47): 10. AMD AI Workbench (AIWB), 11. ggml-org/llama.cpp, 12. Hardware & amdgpu kernel, 1.1 Architecture layers, 1.2 Standard EAI call flow — ROCm HIP via Kaiwo + vLLM, 1.3 Local host path — llama.cpp (Workbench → AIMModel → :8080), 1.4 Components NOT on every token hot path, 1. End-to-end call flow (+39 more)

### Community 28 - "Community 28"
Cohesion: 0.06
Nodes (34): 1.1 — HWE Kernel, 1.2 — Kernel Boot Parameters, 1.3 — ROCm 7.2.3, 1.4 — Verify and Apply gfx1151 Override, 2.1 — Prepare Dedicated Storage Partition, 2.2 — Disable Swap, 2.3 — Install k3s, 2.4 — Deploy Local Container Registry (+26 more)

### Community 29 - "Community 29"
Cohesion: 0.06
Nodes (32): AIRM + AI Workbench, Alternative — k3s script pipeline (lab / debug), [amd-enterprise-ai/aim-engine](https://github.com/amd-enterprise-ai/aim-engine), AMD Enterprise AI Suite — Z13 (amdeai), Build tree and branches, Call flows, Disk checkpoints, Force rebuild (default) (+24 more)

### Community 30 - "Community 30"
Cohesion: 0.07
Nodes (29): 10. Autoscaling, 11. gfx1151 (Strix Halo) Limitations, 12. Installation in This Repo, 13. Observability, 14. Related Docs, 1. What AIM Engine Is, 2. Repository Structure, 3. CRD Inventory (+21 more)

### Community 31 - "Community 31"
Cohesion: 0.07
Nodes (26): 1. OpenSSH server, 2. Passwordless sudo for your user, 3. Remove existing k3s (if present), 4. Optional: Docker Hub credentials, Alternative: k3s script pipeline, bloom-gfx1151.yaml reference, Changes applied to reach working state, Differences from Instinct Bloom install (+18 more)

### Community 32 - "Community 32"
Cohesion: 0.07
Nodes (26): 10. URL validation log (2026-06-06), 11. Local references (amdeai repo), 1. Executive summary, 2.1 Official platform overview, 2.2 Inference call flows, 2. Platform coverage matrix (chapter-by-chapter), 3.1 Official on-premises path, 3.2 Our gfx1151 path (+18 more)

### Community 33 - "Community 33"
Cohesion: 0.11
Nodes (17): 2026-06-06 (initial — HIP blocked), 2026-06-08 (after G9 fix — PASS), amdeai repository changes (this repo), Fix G1 — MMVQ RDNA3_5 parameter table, Fix G2 — MMQ tile sizes for RDNA3_5, Fix G3 — Disable fused topk-MoE on RDNA3_5, Fix G4–G8 — Environment and platform workarounds, Fix G9 — Remove `amdgpu-dkms`; use in-tree `amdgpu` from OEM kernel (+9 more)

### Community 34 - "Community 34"
Cohesion: 0.20
Nodes (9): Backends on gfx1151, Build commands, Call flow: ggml-org/llama.cpp (local inference), Downward path — HIP (standard ROCm, after gfx1151 patches), Downward path (prompt → hardware) — Vulkan (Gemma 4 default), Files to read, Relation to standard EAI path, SLM test (before/after patches) (+1 more)

### Community 35 - "Community 35"
Cohesion: 0.20
Nodes (9): AIM registration (AIM Engine v0.2.x), Backends on gfx1151, Call flow: Gemma 4 31B (local inference via AIMModel), Coexistence with 26B-A4B, Deploy, Relation to standard EAI path, Service, Upward path (+1 more)

### Community 36 - "Community 36"
Cohesion: 0.22
Nodes (8): Call flow: ROCm + host kernel (memory and compute substrate), Memory and platform setup (gfx1151), Role in the EAI suite, Source / docs, Standard HIP inference path (downward), Upward (completion), Verification, Vulkan path (local Gemma 4 workaround)

### Community 37 - "Community 37"
Cohesion: 0.22
Nodes (8): Call flow: ROCm/k8s-device-plugin, Chat prompt path, Downward (registration), gfx1151 environment (DaemonSet), Node labels (Kaiwo scheduling), Pod allocation (cluster inference), Source reading, Upward

### Community 38 - "Community 38"
Cohesion: 0.31
Nodes (8): diag-hip-gfx1151.sh script, dmesg_after(), dmesg_mark(), GGML_CUDA_ENABLE_UNIFIED_MEMORY, HSA_ENABLE_SDMA, HSA_OVERRIDE_GFX_VERSION, MIOPEN_FIND_ENFORCE, run_case()

### Community 39 - "Community 39"
Cohesion: 0.25
Nodes (7): Call flow: k3s (Kubernetes runtime), Chat-related traffic, Downward (API request), Install flow (script `02-kubernetes.sh`), Not involved, Upward (status), Verification

### Community 40 - "Community 40"
Cohesion: 0.25
Nodes (7): AIRM, Call flow: AMD AI Workbench + AIRM, Deploy, Entry (top of stack), Model resolution, Response path, Two inference modes

### Community 41 - "Community 41"
Cohesion: 0.25
Nodes (7): End-to-end call flow: chat prompt → hardware → response, Layer summary, Local host path — llama.cpp (Workbench → AIMModel → host :8080), Path selection on gfx1151, Per-repository call-flow docs, Source trees, Standard path — ROCm HIP via Kaiwo + vLLM

### Community 42 - "Community 42"
Cohesion: 0.29
Nodes (6): Call flow: silogen/kaiwo, Chat prompt path (standard cluster inference), Downward (job → pod → HIP), ResourceFlavor (this stack), ROCm env in GPU pods, Source reading

### Community 43 - "Community 43"
Cohesion: 0.29
Nodes (6): Bloom phases (Ansible tags), Call flow: silogen/cluster-bloom, Chat prompt path, gfx1151-specific tasks (`GPU_GFX1151: true`), Upward, Workflow (gfx1151)

### Community 44 - "Community 44"
Cohesion: 0.52
Nodes (6): latest_version_dir(), main(), unignore_ancestors(), unignore_tree(), Path, str

### Community 45 - "Community 45"
Cohesion: 0.33
Nodes (5): Call flow: Layer 4 platform (Helm charts), Deploy, Per-component summary, Role in EAI suite, Standard inference interaction

### Community 46 - "Community 46"
Cohesion: 0.33
Nodes (5): Call flow: silogen/cluster-forge, Chat prompt path, Upward, What gets installed, Workflow

### Community 47 - "Community 47"
Cohesion: 0.33
Nodes (5): Call flow: amd-enterprise-ai/aim-engine, Chat path (local Gemma), Downward, Standard vs local, Upward

### Community 48 - "Community 48"
Cohesion: 0.40
Nodes (4): Call flow: prerequisites (build toolchain), Purpose, Relation to call flows, Study tree sync

### Community 49 - "Community 49"
Cohesion: 0.40
Nodes (4): 08-gemma4-31b.sh script, KUBECONFIG, MY_IP, PATH

### Community 50 - "Community 50"
Cohesion: 0.40
Nodes (4): validate-hip-gfx1151.sh script, HSA_ENABLE_SDMA, HSA_OVERRIDE_GFX_VERSION, MIOPEN_FIND_ENFORCE

## Knowledge Gaps
- **321 isolated node(s):** `python.defaultInterpreterPath`, `python.terminal.activateEnvironment`, `markdownMermaidZoom.controls.show`, `markdownMermaidZoom.fullscreen`, `markdownMermaidZoom.darkModeTheme` (+316 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `python.defaultInterpreterPath`, `python.terminal.activateEnvironment`, `markdownMermaidZoom.controls.show` to the rest of the system?**
  _329 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 27` be split into smaller, more focused modules?**
  _Cohesion score 0.041666666666666664 - nodes in this community are weakly interconnected._
- **Should `Community 28` be split into smaller, more focused modules?**
  _Cohesion score 0.05714285714285714 - nodes in this community are weakly interconnected._
- **Should `Community 29` be split into smaller, more focused modules?**
  _Cohesion score 0.06060606060606061 - nodes in this community are weakly interconnected._
- **Should `Community 30` be split into smaller, more focused modules?**
  _Cohesion score 0.06666666666666667 - nodes in this community are weakly interconnected._
- **Should `Community 31` be split into smaller, more focused modules?**
  _Cohesion score 0.07407407407407407 - nodes in this community are weakly interconnected._
- **Should `Community 32` be split into smaller, more focused modules?**
  _Cohesion score 0.07407407407407407 - nodes in this community are weakly interconnected._