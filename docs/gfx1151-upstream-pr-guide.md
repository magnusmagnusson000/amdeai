# gfx1151 (Strix Halo) — upstream contribution guide

This document records **every code change** made to enable ROCm HIP inference on gfx1151 (Radeon 8060S, RDNA 3.5), with reproduction steps and upstream PR targets. It is intended for teams maintaining **llama.cpp**, **ROCm**, **k8s-device-plugin**, and **Kaiwo**.

**Hardware:** Asus Z13 · Ryzen AI Max+ · Radeon 8060S (gfx1151) · 128 GB LPDDR5x · Ubuntu 24.04  
**Branch (llama.cpp):** `gfx1151-rdna35-tuning` in `~/eai-build/llama.cpp/`  
**Branch (amdeai):** `gfx1151-rocm-enable` in this repository

---

## Summary table

| ID | Issue | Component | Fix | Upstream target |
|----|-------|-----------|-----|-----------------|
| G1 | MMVQ routes RDNA3_5 → RDNA2 (`nwarps=1`) | llama.cpp `mmvq.cu` | Add `MMVQ_PARAMETERS_RDNA3_5` | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) |
| G2 | MMQ tile sizes not tuned for gfx1151 | llama.cpp `mmq.cuh` | `mmq_x=48`, `mmq_y=64`, `nwarps=4` | ggml-org/llama.cpp |
| G3 | Fused topk-MoE corrupts router on gfx1151 | llama.cpp `topk-moe.cu` | Disable fusion on RDNA3_5 | ggml-org/llama.cpp ([#21416](https://github.com/ggml-org/llama.cpp/issues/21416)) |
| G4 | PERMISSION_FAULT (0x3) on large HIP loads | ROCm SDMA / UMA | `HSA_ENABLE_SDMA=0` | Env workaround; [ROCm#6186](https://github.com/ROCm/ROCm/issues/6186) |
| G5 | MIOpen CK grouped-conv GPU lockup | MIOpen / TheRock | `MIOPEN_FIND_ENFORCE=1` | [TheRock#5259](https://github.com/ROCm/TheRock/issues/5259) |
| G6 | Firmware MES 0x83 GPU hang | linux-firmware | Stay on MES 0x80 or `amdgpu.cwsr_enable=0` | [ROCm#5724](https://github.com/ROCm/ROCm/issues/5724) |
| G7 | KFD ABI <1.20 instability | libhsakmt | Kernel ≥6.17, KFD 1.20+ | ROCm/rocm-systems |
| G8 | AOTriton experimental only | PyTorch/TheRock | `TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` | TheRock nightly wheels |
| **G9** | **`amdgpu-dkms` overrides in-kernel driver → HIP page faults** | **Ubuntu / DKMS** | **Remove `amdgpu-dkms`; boot `linux-oem-24.04d`** | **[ROCm#6146](https://github.com/ROCm/ROCm/issues/6146); [ROCm#5890](https://github.com/ROCm/ROCm/issues/5890)** |

---

## Fix G1 — MMVQ RDNA3_5 parameter table

**File:** `ggml/src/ggml-cuda/mmvq.cu`

**Problem:** gfx1150/gfx1151 compile with `RDNA3_5` but were routed to `MMVQ_PARAMETERS_RDNA2`, forcing `nwarps=1` despite 1536-VGPR occupancy class (same as gfx1100). This degrades decode throughput and can corrupt MoE expert matmul outputs.

**Change:**

1. Add `MMVQ_PARAMETERS_RDNA3_5` to the `mmvq_parameter_table_id` enum (between RDNA2 and RDNA3_0).
2. Route `#elif defined(RDNA3_5)` → `MMVQ_PARAMETERS_RDNA3_5` in `get_device_table_id()` (device and host).
3. In `calc_nwarps()`, add RDNA3_5 block: `nwarps=4` for Q4_K, Q4_0, Q5_*, Q8_0, Q6_K, IQ4_NL at `ncols_dst=1`.

**Related upstream work:** [PR #21344](https://github.com/ggml-org/llama.cpp/pull/21344), [issue #21284](https://github.com/ggml-org/llama.cpp/issues/21284)

**Test:**

```bash
cd ~/eai-build/llama.cpp
cmake -B build-hip -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 -DCMAKE_BUILD_TYPE=Release
cmake --build build-hip -j$(nproc)
./build-hip/bin/llama-bench --model ~/models/Qwen3-0.6B-Q4_K_M.gguf \
  --n-gpu-layers 99 -p 512 -n 128 -r 3
```

---

## Fix G2 — MMQ tile sizes for RDNA3_5

**File:** `ggml/src/ggml-cuda/mmq.cuh`

**Problem:** Generic HIP MMQ defaults (`mmq_x=64`, `mmq_y=128`, `nwarps=8`) cause VGPR spilling on gfx1151 during MoE prefill.

**Change:**

| Function | RDNA3_5 value |
|----------|---------------|
| `get_mmq_x_max_host/device` | 48 |
| `get_mmq_y_host/device` | 64 |
| `mmq_get_nwarps_host/device` | 4 |

**Test:** Same as G1; compare prefill tokens/s on MoE models (Qwen3 MoE, Gemma 4).

---

## Fix G3 — Disable fused topk-MoE on RDNA3_5

**File:** `ggml/src/ggml-cuda/topk-moe.cu`

**Problem:** Gemma 4 26B-A4B on gfx1151 via HIP produces endless `<unused24>` tokens ([#21416](https://github.com/ggml-org/llama.cpp/issues/21416)). Fused `topk_moe_cuda` kernel likely produces corrupted router weights.

**Change:** At start of `ggml_cuda_should_use_topk_moe()`, return `false` when `GGML_CUDA_CC_IS_RDNA3_5(cc)`. Unfused `ARGSORT` + `GET_ROWS` path is used instead.

**Follow-up for upstream:** After G1+G2 land, re-test fusion on gfx1151; if fixed, remove the RDNA3_5 guard.

**Test:**

```bash
./build-hip/bin/llama-cli -m ~/models/gemma-4-26b-a4b-it-Q4_K_M.gguf \
  -ngl 99 -p "Hello" -n 32 --no-display-prompt
# Expect: coherent text, not repeated <unused24>
```

---

## Fix G9 — Remove `amdgpu-dkms`; use in-tree `amdgpu` from OEM kernel

**Symptom:** Every HIP call (`hipMemcpy`, llama.cpp model load) hangs and emits `amdgpu: [gfxhub] page fault … PERMISSION_FAULTS: 0x3` in `dmesg`. Manifests as `llama-cli` spinning at `Loading model...` at 99% CPU, ~4% GPU. No env-var workaround resolves it.

**Root cause:** Ubuntu installs `amdgpu-dkms` (AMD's out-of-tree DKMS driver, version `6.16.x`) alongside the HWE generic kernel. On gfx1151 Strix Halo, the DKMS driver's UMA/HMA page-table mapping is incompatible with the SoC's integrated memory controller, causing all HIP compute operations to fault on first GPU access. The in-kernel `amdgpu` driver shipped with `linux-oem-24.04d` does not have this problem and also loads MES firmware `0x80` instead of the broken `0x83`.

**Verification:**

```bash
# Check which amdgpu is loaded:
modinfo amdgpu | grep filename
# BAD:  /lib/modules/6.17.0-35-generic/updates/dkms/amdgpu.ko.zst  ← DKMS override
# GOOD: /lib/modules/6.17.0-1025-oem/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst

# Check MES firmware:
sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep MES
# GOOD: MES feature version: 1, firmware version: 0x00000080
# BAD:  MES feature version: 1, firmware version: 0x00000083

# Reproduce the fault with DKMS loaded:
hipcc /tmp/hipmemcpy.cpp -o /tmp/hipmemcpy && /tmp/hipmemcpy
# BAD:  hipMemcpy H2D: no error  (but dmesg shows PERMISSION_FAULTS)
# GOOD: hipMemcpy H2D: no error  (and dmesg is clean)
```

**Fix:**

```bash
# Remove the DKMS override:
sudo apt remove -y amdgpu-dkms amdgpu-dkms-firmware

# Install and boot the OEM kernel (ships in-tree amdgpu + correct MES 0x80):
sudo apt install -y linux-oem-24.04d
sudo reboot
# At GRUB, boot "Ubuntu, with Linux 6.17.0-1025-oem" (usually first entry after install)
```

**Automated check** — `scripts/01-host-rocm.sh` now detects and removes `amdgpu-dkms` automatically if present, and installs `linux-oem-24.04d`. `scripts/validate-hip-gfx1151.sh` blocks execution if the DKMS module is still loaded.

**References:**
- [ROCm#6146](https://github.com/ROCm/ROCm/issues/6146) — `hipMemcpy` page fault on gfx1151 with kernel 6.17 generic; resolved by switching to `6.14.0-1018-oem` + removing `amdgpu-dkms`
- [ROCm#5890](https://github.com/ROCm/ROCm/issues/5890) — `amdgpu-dkms` page fault under ROCm 7.2 on gfx1151; resolved by `sudo amdgpu-uninstall`
- [ROCm#6186](https://github.com/ROCm/ROCm/issues/6186) — persistent PERMISSION_FAULTS on Strix Halo; env var `HSA_ENABLE_SDMA=0` is a secondary mitigation
- [TheRock#2991](https://github.com/ROCm/TheRock/issues/2991) — upstream tracking issue for gfx1151 UMA driver stability
- [AMD Radeon/Ryzen install guide](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installryz/native_linux/install-ryzen.html) — official AMD guidance: use OEM kernel and remove `amdgpu-dkms` on Ryzen AI

**Status (2026-06-08):** RESOLVED on this system. `hipMemcpy` clean, no page faults. Full HIP inference validated:

| Model | Prompt t/s | Gen t/s | MoE fault |
|-------|-----------|---------|-----------|
| Phi-4-mini-instruct Q4_K_M (dense SLM) | 297 | 68 | n/a |
| Gemma 4 26B-A4B Q4_K_M (MoE) | 114 | 36 | None — no `<unused>` tokens |

---

## Fix G4–G8 — Environment and platform workarounds

These are applied in `scripts/03-gpu-plugin.sh`, `scripts/07-llama-cpp.sh` (systemd unit), and `/etc/environment`:

```bash
HSA_OVERRIDE_GFX_VERSION=11.5.1
HSA_ENABLE_SDMA=0
MIOPEN_FIND_ENFORCE=1
PYTORCH_TUNABLEOP_ENABLED=1
TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
```

**GRUB (required for 128 GiB VRAM visibility):**

```
amdgpu.gttsize=131072
ttm.pages_limit=33554432
amd_iommu=off
```

**Firmware check:**

```bash
sudo cat /sys/kernel/debug/dri/1/amdgpu_firmware_info | grep MES
# Must NOT be 0x83 (hang). Use MES 0x80 or amdgpu.cwsr_enable=0 if needed.
```

---

## SLM validation models

Use small models before testing Gemma 4:

| Model | Type | Size | Purpose |
|-------|------|------|---------|
| Qwen3-0.6B Q4_K_M | Dense | ~400 MB | Baseline HIP stability |
| Qwen3-0.6B-A0.5B Q4_K_M | MoE | ~400 MB | MoE router without Gemma bug |
| phi-4-mini-instruct Q4_K_M | Dense | ~2.5 GB | Alternative SLM |
| Gemma 4 26B-A4B Q4_K_M | MoE | ~14 GB | Full regression after fixes |

Download example:

```bash
huggingface-cli download bartowski/Qwen3-0.6B-GGUF \
  --include "Qwen3-0.6B-Q4_K_M.gguf" --local-dir ~/models/
```

---

## How to submit upstream PRs

### llama.cpp (G1–G3)

1. Fork [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp).
2. Cherry-pick commits from branch `gfx1151-rdna35-tuning` in `~/eai-build/llama.cpp/`.
3. PR title: `HIP: gfx1151 RDNA3_5 MMVQ/MMQ tuning and MoE fusion workaround`
4. Include `llama-bench` before/after on gfx1151 and note [#21416](https://github.com/ggml-org/llama.cpp/issues/21416).

### ROCm stack (G4–G8)

- **SDMA fault:** Track [ROCm#6186](https://github.com/ROCm/ROCm/issues/6186); env var is interim.
- **MIOpen CK lockup:** Track [TheRock#5259](https://github.com/ROCm/TheRock/issues/5259); Winograd workaround via `MIOPEN_FIND_ENFORCE=1`.
- **TheRock nightlies:** `https://rocm.nightlies.amd.com/v2/gfx1151/` for PyTorch wheels targeting gfx1151.

### k8s-device-plugin / Kaiwo

No source patches required. Ensure GPU pod specs inherit the env vars above (DaemonSet env in `03-gpu-plugin.sh`; KaiwoJob pod template for cluster workloads).

---

## amdeai repository changes (this repo)

| File | Change |
|------|--------|
| `scripts/sync-eai-build.sh` | Git pull all 22 study-tree repos |
| `scripts/lib/force-build.sh` | `ensure_git_repo()` preserves local feature branches |
| `scripts/03-gpu-plugin.sh` | gfx1151 ROCm env vars in DaemonSet |
| `scripts/07-llama-cpp.sh` | HIP build + branch preservation + systemd env |
| `scripts/01-host-rocm.sh` | Auto-remove `amdgpu-dkms`; install `linux-oem-24.04d`; add `amdgpu.cwsr_enable=0` to GRUB |
| `scripts/validate-hip-gfx1151.sh` | SLM → Phi-4-mini; DKMS guard; `--single-turn` exit fix |
| `scripts/diag-hip-gfx1151.sh` | Deep HIP diagnostic runner (kernel logs, per-case timeouts) |
| `docs/call-flows/*.md` | ROCm as standard path; Vulkan as Gemma workaround |
| `docs/CALL_FLOW_OVERVIEW.md` | Dual-path overview |
| `docs/OVERVIEW.md` | Standard vs gfx1151-specific paths |
| `docs/gfx1151-upstream-pr-guide.md` | Added G9 (amdgpu-dkms root cause + fix) |
| `README.md` | Full install guide; updated validation results; G9 in gfx1151 notes |

---

## Revision history

| Date | Notes |
|------|-------|
| 2026-06-06 | G1–G3 patches applied + documentation; `gfx1151-rdna35-tuning` merged to llama.cpp master @ `0ab06d382`; HIP build OK |
| 2026-06-08 | **Root cause identified and fixed (G9):** `amdgpu-dkms` was overriding in-kernel driver, causing HIP page faults on every compute op. Removed DKMS; installed `linux-oem-24.04d` (MES 0x80); full HIP inference now validated |

## Runtime validation

### 2026-06-06 (initial — HIP blocked)

| Step | Result |
|------|--------|
| `git pull origin master` + merge gfx1151 branch | OK — conflict in `mmvq.cu` resolved (kept RDNA3_5 + TURING tables) |
| HIP cmake/build `AMDGPU_TARGETS=gfx1151` | OK — `build-hip/bin/llama-cli` @ `0ab06d382` |
| `llama-cli --list-devices` | OK — gfx1151 detected |
| SLM / Gemma HIP inference | **FAIL** — `amdgpu: [gfxhub] page fault PERMISSION_FAULTS: 0x3` on every run; root cause: `amdgpu-dkms` overriding in-kernel driver |

### 2026-06-08 (after G9 fix — PASS)

**System state:**
- Kernel: `6.17.0-1025-oem`
- `amdgpu`: in-tree (`/lib/modules/6.17.0-1025-oem/kernel/…/amdgpu.ko.zst`)
- MES firmware: `0x00000080` (safe)
- GRUB: `amdgpu.gttsize=131072 ttm.pages_limit=33554432 amd_iommu=off amdgpu.cwsr_enable=0`
- GTT pool: `137438953472` bytes (~128 GiB)

| Step | Result |
|------|--------|
| `hipMemcpy` smoke test | **PASS** — no error, no kernel faults |
| `llama-cli --list-devices` | OK — `ROCm0: AMD Radeon Graphics (131072 MiB, ~119 GiB free)` |
| Phi-4-mini SLM ngl=99 | **PASS** — 297 t/s prompt, 68 t/s gen |
| Gemma 4 26B-A4B MoE ngl=99 | **PASS** — 114 t/s prompt, 36 t/s gen, no `<unused>` tokens |
| `scripts/validate-hip-gfx1151.sh` exit code | **0** |

**Reproduce validation:**

```bash
sudo systemctl stop ollama
bash scripts/validate-hip-gfx1151.sh
# Expected output ends with:
# PASS: No <unused> token repeat detected in Gemma 4 HIP output
# === Done ===
```

> **Note on `rocm-smi --showmeminfo vram`:** on Strix Halo the reported VRAM total stays ~4 GiB — this is the carved-out `vis_vram` pool; the full GTT (~128 GiB) is what `llama-cli --list-devices` and `/sys/class/drm/card1/device/mem_info_gtt_total` show. This is expected and not an indicator of misconfiguration.
