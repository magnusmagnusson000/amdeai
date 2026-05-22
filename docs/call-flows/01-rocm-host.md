# Call flow: ROCm + host kernel (memory and compute substrate)

**Install:** APT `rocm` meta-package, `amdgpu` kernel driver (in-tree).

## Role in chat path

- **Host llama.cpp Vulkan:** uses **Mesa RADV** + `amdgpu` DRM; ROCm userspace is not the primary API for token ops.
- **In-cluster ROCm workloads:** HIP runtime → **ROCclr** → **KFD** ioctl → same `amdgpu` hardware.

## Downward (memory visibility for GPU workloads)

1. **GRUB** `amdgpu.gttsize`, `ttm.pages_limit` → larger GTT/TTM pool (target ~128 GiB visible).
2. **Kernel `amdgpu`** initializes unified memory on Strix Halo.
3. **`/etc/environment`** `HSA_OVERRIDE_GFX_VERSION=11.5.1` → ROCm tools/containers report gfx1151 ISA.
4. **BO allocation:** HIP or Vulkan allocate buffers → pinned in GTT/VRAM range.
5. **Compute:** kernel schedules rings → **gfx1151** executes kernels.

## Upward (completion)

- GPU interrupt → DRM fence → Vulkan fence or HIP event.
- Userspace resumes graph (llama.cpp or vLLM).

## Tools for verification (not in hot path)

- `rocminfo` — HSA agents, ISA name.
- `rocm-smi` — VRAM accounting (should approach hardware RAM after GRUB tuning + reboot).

## Source / docs to read

- [ROCm install guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/)
- [Environment variables](https://rocm.docs.amd.com/en/reference/env-variables.html)
- Kernel: `Documentation/gpu/amdgpu/` (on kernel.org, matches your running kernel)

## Chat prompt path

**Hardware and memory foundation** for all GPU backends; **direct** for HIP pods, **indirect** for Vulkan via DRM same driver.
