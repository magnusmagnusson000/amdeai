# Call flow: ROCm + host kernel (memory and compute substrate)

**Install:** APT `rocm` meta-package, `amdgpu` kernel driver (in-tree).  
**Script:** `scripts/01-host-rocm.sh`  
**Upstream guide:** [gfx1151-upstream-pr-guide.md](../gfx1151-upstream-pr-guide.md)

## Role in the EAI suite

ROCm is the **standard GPU compute backbone** for the Enterprise AI suite:

- **Cluster inference (primary):** vLLM / PyTorch → HIP → ROCclr → KFD → gfx1151
- **Device plugin:** Builds and runs against ROCm headers; advertises `amd.com/gpu`
- **Host llama.cpp (optional):** HIP backend after gfx1151 patches; Vulkan uses same `amdgpu` DRM driver

## Standard HIP inference path (downward)

1. Container or host process calls `hipLaunchKernel` / hipBLAS.
2. **libamdhip64** → **ROCclr** (in `clr/`) schedules on HSA queue.
3. **KFD** ioctl — queue create, IB submit to GFX ring.
4. **amdgpu** kernel executes on **gfx1151** (40 CU, unified LPDDR5x).
5. Completion → HIP event → userspace resumes (vLLM, llama.cpp, etc.).

## Memory and platform setup (gfx1151)

1. **GRUB:** `amdgpu.gttsize=131072`, `ttm.pages_limit=33554432`, `amd_iommu=off`
2. **`/etc/environment`:** `HSA_OVERRIDE_GFX_VERSION=11.5.1`
3. **Workaround env (pods + llama-server):**
   - `HSA_ENABLE_SDMA=0` — avoids PERMISSION_FAULT on UMA ([#6186](https://github.com/ROCm/ROCm/issues/6186))
   - `MIOPEN_FIND_ENFORCE=1` — avoids MIOpen CK lockup ([#5259](https://github.com/ROCm/TheRock/issues/5259))
4. **Firmware:** MES 0x80 preferred; avoid MES 0x83 hang ([#5724](https://github.com/ROCm/ROCm/issues/5724))

## Vulkan path (local Gemma 4 workaround)

Host llama.cpp with **Mesa RADV** uses DRM only (no HIP per token). Used for Gemma 4 MoE until HIP fusion is fixed ([#21416](https://github.com/ggml-org/llama.cpp/issues/21416)).

## Upward (completion)

- GPU interrupt → KFD/DRM fence → HIP event or Vulkan fence
- Userspace continues graph (token generation)

## Verification

```bash
rocminfo | grep gfx          # expect gfx1151
rocm-smi --showmeminfo vram  # expect ~128 GiB after GRUB + reboot
cat /sys/class/kfd/kfd/version
```

## Source / docs

- [ROCm install guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/)
- [ROCm on Radeon/Ryzen (gfx1151)](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/)
- Study tree: `~/eai-build/rocm/` (see `STACK_INDEX.md`)
