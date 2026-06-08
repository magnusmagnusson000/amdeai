# On-premises installation on Strix Halo (gfx1151) via Cluster Bloom

**Hardware:** Asus Z13 / Ryzen AI Max+ / Radeon 8060S (**gfx1151**, 128 GB unified memory)  
**OS:** Ubuntu 24.04 (noble), kernel ≥ 6.17 recommended  
**Installer:** [Cluster Bloom](https://github.com/silogen/cluster-bloom) with `GPU_GFX1151: true`

This guide mirrors the [official on-premises install](https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html) but uses the gfx1151-specific Bloom path instead of the Instinct (MI300X) defaults.

---

## Prerequisites

| Requirement | gfx1151 (Z13) | Instinct (official doc) |
|-------------|---------------|-------------------------|
| GPU | Radeon 8060S / gfx1151 | MI300X / MI325X / M350X / MI355X |
| ROCm | **7.2.3** (Radeon/Ryzen stream) | 7.0.2 recommended |
| Kubernetes | RKE2 via Bloom | RKE2 via Bloom |
| Disk | Single NVMe OK (`NO_DISKS_FOR_CLUSTER`) | 500 GB+ root, 3 TB+ data NVMe |
| CPU | 20+ cores (Z13 meets) | 20+ cores |
| Passwordless sudo | Required for your **login user** over SSH | Required |
| OpenSSH server (`sshd` on :22) | **Required** — Bloom Ansible connects to `127.0.0.1` via SSH | Required |
| Existing Kubernetes | **No k3s/RKE2** on the host (port 6443 conflict) | Clean host or `bloom cleanup` |

**Before Bloom:** Ensure kernel ≥ 6.17 for KFD ABI ≥ 1.20. **Critical: do not have `amdgpu-dkms` installed** — it causes HIP page faults on gfx1151 regardless of env-var workarounds. Use `linux-oem-24.04d` (ships in-tree `amdgpu`). See [gfx1151-upstream-pr-guide.md — G9](gfx1151-upstream-pr-guide.md#fix-g9--remove-amdgpu-dkms-use-in-tree-amdgpu-from-oem-kernel) for details.

---

## Host prerequisites (run before `bloom cli`)

Bloom runs Ansible inside a container and connects back to the host over **SSH to `127.0.0.1:22`**. If any step below is skipped, the playbook fails immediately (often with `Connection refused` on port 22) and **nothing is installed** — despite endpoint URLs printed at the end (those are templates for a successful run).

### 1. OpenSSH server

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
ss -tlnp | grep ':22'    # expect sshd listening
```

### 2. Passwordless sudo for your user

You may invoke Bloom with `sudo`, but Ansible runs tasks as `SUDO_USER` (e.g. `magnus`) over SSH. That user needs passwordless sudo:

```bash
echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/cluster-bloom-nopasswd
sudo chmod 440 /etc/sudoers.d/cluster-bloom-nopasswd
sudo -n true && echo "passwordless sudo OK"
```

### 3. Remove existing k3s (if present)

Bloom installs **RKE2**, not k3s. An existing k3s cluster conflicts on API port **6443** and kubeconfig paths. Before Bloom:

```bash
# If you used amdeai k3s scripts:
/usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
# Or check:
kubectl get nodes 2>/dev/null && echo "k3s still present — remove before Bloom"
```

`bloom cleanup` removes a **previous Bloom/RKE2** install only; it does **not** uninstall k3s.

### 4. Optional: Docker Hub credentials

Add to [bloom-gfx1151.yaml](../bloom-gfx1151.yaml) to reduce image-pull rate limits during Cluster Forge:

```yaml
DOCKERHUB_USER: "your-user"
DOCKERHUB_TOKEN: "your-token"
```

---

## Quick start (~20 min)

```bash
cd /home/magnus/projects/amdeai

# 0. Prerequisites (see section above)
sudo apt install -y openssh-server && sudo systemctl enable --now ssh
echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/cluster-bloom-nopasswd
# Remove k3s if installed (see Host prerequisites)

# 1. Bloom binary — gfx1151 needs feat/gfx1151-support until upstream release
#    Option A: build from ~/eai-build/cluster-bloom (branch feat/gfx1151-support)
#      cd ~/eai-build/cluster-bloom && go build -o /home/magnus/projects/amdeai/bloom .
#    Option B: copy a locally built binary
#      cp /tmp/bloom-gfx1151 ./bloom
#    Option C: upstream release (no GPU_GFX1151 until merged)
#      wget -O bloom https://github.com/silogen/cluster-bloom/releases/latest/download/bloom
chmod +x bloom

# 2. Set domain to node IP + nip.io
NODE_IP=$(hostname -I | awk '{print $1}')
sed -i "s|^DOMAIN:.*|DOMAIN: \"${NODE_IP}.nip.io\"|" bloom-gfx1151.yaml

# 3. Install full stack (~15–25 min; hundreds of Ansible tasks on success)
sudo ./bloom cli bloom-gfx1151.yaml
```

**Success looks like:** many `ok` / `changed` tasks, not `0 ok, 1 failed`. Check `bloom.log` in this directory if unsure.

If Bloom reports **REBOOT REQUIRED** after GRUB or `/etc/environment` changes, reboot and re-run:

```bash
sudo reboot
# after reboot:
sudo ./bloom cli bloom-gfx1151.yaml
```

---

## What Bloom installs (gfx1151 path)

With `GPU_GFX1151: true`, Bloom performs:

1. **ROCm 7.2.3** from `repo.radeon.com/rocm/apt` (Radeon/Ryzen path, not `amdgpu-install` Instinct path)
2. **GRUB** unified-memory params: `amdgpu.gttsize=131072 ttm.pages_limit=33554432 amd_iommu=off`
3. **Environment** in `/etc/environment`: `HSA_OVERRIDE_GFX_VERSION=11.5.1`, `HSA_ENABLE_SDMA=0`, `MIOPEN_FIND_ENFORCE=1`, etc.
4. **RKE2** single-node cluster
5. **Platform**: MetalLB, cert-manager, ArgoCD (small cluster)
6. **Cluster Forge** GitOps bootstrap → Kaiwo, AIM Engine, AIRM, AI Workbench
7. **GPU device plugin** DaemonSet with gfx1151 env vars + Kaiwo node labels

Equivalent to our k3s scripts `01`–`06b` (except local llama — see below).

---

## Post-install verification

```bash
# GRUB / unified memory
grep -E 'gttsize|pages_limit|iommu' /proc/cmdline

# ROCm / gfx1151
rocminfo | grep gfx1151
rocm-smi --showmeminfo vram    # expect ~128 GiB, not ~4 GiB

# Kubernetes GPU resource
kubectl get node -o custom-columns=NAME:.metadata.name,GPU:status.capacity.amd\\.com/gpu

# Kaiwo labels
kubectl get node --show-labels | grep kaiwo

# HIP validation (from amdeai repo)
bash scripts/validate-hip-gfx1151.sh
```

**Service URLs** (replace `<IP>` with node IP):

| Service | URL |
|---------|-----|
| AI Workbench | `https://aiwbui.<IP>.nip.io` |
| AIRM | `https://airmui.<IP>.nip.io` |
| Keycloak | `https://keycloak.<IP>.nip.io` |

Default admin: `silogen-admin` (password set at bootstrap).

Set Hugging Face token in Workbench UI secrets for model catalog features.

---

## Optional: local host llama.cpp (not in Bloom)

Cluster Bloom does not install host-side `llama-server`. For Workbench chat via AIMModel → `:8080`:

```bash
bash scripts/07-llama-cpp.sh
```

See [CALL_FLOW_OVERVIEW.md](CALL_FLOW_OVERVIEW.md) for the local vs cluster inference paths.

---

## bloom-gfx1151.yaml reference

See [bloom-gfx1151.yaml](../bloom-gfx1151.yaml) at repo root. Key fields:

| Field | Value | Purpose |
|-------|-------|---------|
| `GPU_GFX1151` | `true` | Enable Strix Halo install path |
| `NO_DISKS_FOR_CLUSTER` | `true` | Skip Longhorn disk prep (single NVMe laptop) |
| `SKIP_RANCHER_PARTITION_CHECK` | `true` | Skip 500 GB `/var/lib/rancher` check |
| `CLUSTER_SIZE` | `small` | Single-node Z13 demo |
| `PRELOAD_IMAGES` | `""` | Skip large image preload on laptop |
| `DOCKERHUB_USER` / `DOCKERHUB_TOKEN` | optional | Authenticated pulls during Cluster Forge |

---

## Differences from Instinct Bloom install

| Topic | Instinct (default Bloom) | gfx1151 (`GPU_GFX1151: true`) |
|-------|--------------------------|----------------------------------|
| ROCm install | `amdgpu-install` 7.1.1 + DKMS | Direct apt 7.2.3 Radeon/Ryzen repos |
| GRUB | Not configured | Unified-memory GTT/TTM params |
| HSA env | Not set | `/etc/environment` gfx1151 vars |
| Device plugin | Generic labels | gfx1151 env + Kaiwo labels |
| Storage | Longhorn on raw NVMe | `NO_DISKS_FOR_CLUSTER` (local-path) |

---

## Alternative: k3s script pipeline

The scripted k3s path in [README.md](../README.md) remains available for lab/debug. Both paths target the same EAI services; Bloom is the official installer. Do not keep both k3s and Bloom/RKE2 on the same host.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ssh: connect to host 127.0.0.1 port 22: Connection refused` | `sshd` not running | Install/start `openssh-server` (see [Host prerequisites](#host-prerequisites-run-before-bloom-cli)) |
| `0 ok, 1 failed` in recap; endpoints still printed | Playbook failed on first task; banner is not proof of success | Read `bloom.log`; fix prerequisites; re-run |
| `sudo: ./bloom: command not found` | Binary not in repo root | `cp` built binary or `go build` into `./bloom` |
| `rocminfo` OK but VRAM ≈ 4 GiB | Expected — `rocm-smi` reports `vis_vram` carve-out (~4 GiB); actual GPU memory is GTT (~128 GiB). Check `cat /sys/class/drm/card1/device/mem_info_gtt_total` and `llama-cli --list-devices` | Not an error; proceed |
| HIP page faults / `llama-cli` hangs at `Loading model...` | `amdgpu-dkms` overriding in-kernel driver | `sudo apt remove -y amdgpu-dkms amdgpu-dkms-firmware && sudo apt install -y linux-oem-24.04d && sudo reboot` — see [G9](gfx1151-upstream-pr-guide.md#fix-g9--remove-amdgpu-dkms-use-in-tree-amdgpu-from-oem-kernel) |
| `amdgpu: [gfxhub] page fault … PERMISSION_FAULTS: 0x3` in dmesg | Same — DKMS amdgpu driver | Same fix as above |
| Port 6443 already in use | k3s or old RKE2 still present | Remove k3s or `sudo ./bloom cleanup bloom-gfx1151.yaml` then retry |

---

## Validation log (development)

Automated checks on Z13 (`feat/gfx1151-support` branch):

| Check | Result |
|-------|--------|
| `go test ./pkg/config/...` (cluster-bloom) | Pass (38 schema fields incl. `GPU_GFX1151`) |
| `go build` bloom binary from source | Pass |
| `./bloom cli bloom-gfx1151.yaml --export` | Pass — playbook includes gfx1151 tasks |
| `./bloom help` lists `GPU_GFX1151` | Pass |
| `rocminfo \| grep gfx1151` on Z13 | Pass |
| Full `sudo ./bloom cli` end-to-end | **Manual** — requires clean host or `bloom cleanup`; conflicts with existing k3s lab cluster |
| `hipMemcpy` / HIP inference via `validate-hip-gfx1151.sh` | **PASS** (2026-06-08, kernel `6.17.0-1025-oem`, `amdgpu-dkms` removed) |

After full Bloom install on a clean Z13, run the [Post-install verification](#post-install-verification) section and `bash scripts/validate-hip-gfx1151.sh`.

---

## Related docs

- [GFX1151_EAI_DOCS_COMPARISON.md](GFX1151_EAI_DOCS_COMPARISON.md) — official vs local stack comparison
- [CALL_FLOW_OVERVIEW.md](CALL_FLOW_OVERVIEW.md) — inference call flows
- [gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md) — patches G1–G9 (incl. amdgpu-dkms root cause)
- [ROCm Radeon/Ryzen](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/) — AMD gfx1151 ROCm guide
