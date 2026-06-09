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

# 2. Set domain to node IP + nip.io (required before install — see DOMAIN section below)
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

## Install sequence (validated on Z13, 2026-06-08)

A full Enterprise AI stack on gfx1151 requires **three Bloom phases** plus optional GitOps workarounds. Use this order on a clean host.

### Phase 1 — Full Bloom install

```bash
sudo ./bloom cli bloom-gfx1151.yaml
```

This runs node prep (ROCm 7.2.3, GRUB, env vars), RKE2, `deploy_k8s_apps` (MetalLB manifest, local-path, domain/TLS, GPU plugin), and ClusterForge bootstrap.

**Required config in [bloom-gfx1151.yaml](../bloom-gfx1151.yaml):**

| Field | Why |
|-------|-----|
| `DOMAIN: "<IP>.nip.io"` | CoreDNS rewrite in `envoy-gateway-config`; empty domain breaks **all** cluster DNS |
| `INSTALL_ARGOCD: false` | ClusterForge Helm ArgoCD conflicts with Bloom `core-install` (immutable Deployment selectors) |
| `GPU_GFX1151: true` | Enables ROCm Radeon path, GRUB unified memory, gfx1151 device plugin |
| `NO_DISKS_FOR_CLUSTER: true` | Single NVMe laptop; uses local-path `direct` StorageClass |

### Phase 2 — MetalLB + domain/TLS (if skipped or re-applying)

If you previously ran only `--tags deploy_clusterforge`, or HTTPS on `:443` is not programmed, run:

```bash
sudo ./bloom cli bloom-gfx1151.yaml --tags metallb,domain
```

**Expected recap:** `3 ok, 4 changed, 0 failed` (not `0 ok`). This creates:

- `/var/lib/rancher/rke2/server/manifests/metallb-address.yaml` — IPAddressPool + L2Advertisement for node IP
- `cluster-domain` ConfigMap in `default`
- `cluster-tls` TLS secret in `envoy-gateway-system` from RKE2 API server certs

**Tag bug (fixed in `feat/gfx1151-support`):** Older Bloom builds ran the `include_tasks` wrappers but skipped inner tasks when using `--tags metallb,domain` because child tasks lacked Ansible tags. Rebuild bloom from cluster-bloom after pulling the tag fix:

```bash
cd ~/eai-build/cluster-bloom && go build -o /home/magnus/projects/amdeai/bloom .
```

Alternative: `sudo ./bloom cli bloom-gfx1151.yaml --tags deploy_k8s_apps` runs all k8s app tasks including metallb and domain.

### Phase 3 — Wait for GitOps + verify gateway

```bash
kubectl wait --for=condition=ready pod --all -n envoy-gateway-system --timeout=600s
kubectl get gateway -n envoy-gateway-system    # ADDRESS = node IP, PROGRAMMED = True
kubectl get applications.argoproj.io -n argocd
```

HTTPS smoke test (307 redirect to Keycloak is OK):

```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://aiwbui.${NODE_IP}.nip.io/
curl -sk -o /dev/null -w "%{http_code}\n" https://airmui.${NODE_IP}.nip.io/
```

### Phase 4 — GitOps workarounds (if apps OutOfSync / Degraded)

These were required on Z13 when ClusterForge `main` shipped chart defaults incompatible with envoy-gateway:

| Issue | Symptom | Fix |
|-------|---------|-----|
| AIWB chart `2.0.0-rc.1` missing on Docker Hub | `aiwb` sync error, image pull failures | Patch ArgoCD Application `targetRevision` to `1.1.9` |
| AIWB HTTPRoute parent `kgateway-system` | Routes not attached to Gateway | Patch `parentRefs.namespace` to `envoy-gateway-system` on `aiwb-ui-route` and `aiwb-api-route` |
| CoreDNS wildcard `.*\.` from empty domain | ExternalSecrets fail, repo-server DNS errors | Set `DOMAIN` before install; remove bad rewrite from `rke2-coredns` ConfigMap |
| `airm` / `aiwb` Applications missing | Parent `cluster-forge` sync failed during DNS outage | Re-apply cluster-forge helm template or hard-refresh parent Application |

Example AIWB chart patch:

```bash
kubectl patch application aiwb -n argocd --type merge \
  -p '{"spec":{"source":{"targetRevision":"1.1.9"}}}'
```

Example HTTPRoute parent patch:

```bash
kubectl patch httproute aiwb-ui-route -n aiwb --type=json \
  -p '[{"op":"replace","path":"/spec/parentRefs/0/namespace","value":"envoy-gateway-system"}]'
```

After patching, you may suspend auto-sync on affected apps to prevent self-heal from reverting:

```bash
kubectl patch application aiwb -n argocd --type merge \
  -p '{"spec":{"syncPolicy":null}}'
```

---

## What Bloom installs (gfx1151 path)

With `GPU_GFX1151: true`, Bloom performs:

1. **ROCm 7.2.3** from `repo.radeon.com/rocm/apt` (Radeon/Ryzen path, not `amdgpu-install` Instinct path)
2. **GRUB** unified-memory params: `amdgpu.gttsize=131072 ttm.pages_limit=33554432 amd_iommu=off`
3. **Environment** in `/etc/environment`: `HSA_OVERRIDE_GFX_VERSION=11.5.1`, `HSA_ENABLE_SDMA=0`, `MIOPEN_FIND_ENFORCE=1`, etc.
4. **RKE2** single-node cluster
5. **Platform**: MetalLB, cert-manager, local-path storage (`direct` StorageClass), envoy-gateway
6. **Cluster Forge** bootstrap → ArgoCD (Helm), OpenBao, parent Application → Kaiwo, AIM Engine, AIRM, AI Workbench via GitOps
7. **GPU device plugin** DaemonSet with gfx1151 env vars + Kaiwo node labels

With `INSTALL_ARGOCD: false`, Bloom skips its lightweight ArgoCD `core-install` manifest. ClusterForge’s `bootstrap_argocd.yaml` installs the full Helm chart instead (required — the two ArgoCD installs fight over immutable Deployment selectors).

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
| Keycloak | `https://kc.<IP>.nip.io` |
| ArgoCD | `https://argocd.<IP>.nip.io` |
| OpenBao | `https://openbao.<IP>.nip.io` |
| Gitea | `https://gitea.<IP>.nip.io` |

See [Retrieve credentials](#retrieve-credentials) below for login commands. Set Hugging Face token in Workbench UI secrets for model catalog features.

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
| `INSTALL_ARGOCD` | `false` | Let ClusterForge bootstrap ArgoCD (Helm). Bloom `core-install` conflicts on small clusters |
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
| ArgoCD `spec.selector field is immutable` | Bloom `core-install` ArgoCD + ClusterForge Helm ArgoCD | Set `INSTALL_ARGOCD: false` in `bloom-gfx1151.yaml`; `kubectl delete ns argocd` if stuck, re-run `--tags deploy_clusterforge` |
| OpenBao pod Pending, `storageclass "direct" not found` | `NO_DISKS_FOR_CLUSTER` skips local-path in upstream Bloom | Ensure local-path provisioner is deployed (gfx1151 Bloom PR enables this); or copy manifests from `cluster-bloom/.../manifests/local-path/` into `/var/lib/rancher/rke2/server/manifests/` |
| `--tags metallb,domain` shows `0 ok, 0 changed` | Bloom build before tag fix — inner Ansible tasks skipped | Rebuild bloom from `feat/gfx1151-support` (tags on `metallb.yaml` / `domain.yaml` tasks); re-run; expect `3 ok, 4 changed` |
| ExternalSecrets `SecretSyncedError`, pods `CreateContainerConfigError` | CoreDNS rewrite rule with **empty** `domain` — all `*.svc.cluster.local` names resolve to envoy-gateway | Ensure `DOMAIN` is set **before** install. If broken: delete `helmchartconfig/rke2-coredns` in `kube-system`, patch CoreDNS ConfigMap to remove the `rewrite` line, restart `rke2-coredns` and `external-secrets` |
| `airm` / `aiwb` ArgoCD Applications missing | `cluster-forge` parent sync failed while DNS was broken | After DNS fix: `helm template cluster-forge ... \| kubectl apply -f -` (see ClusterForge clone under `.bloom/clusterforge/`) or hard-refresh `cluster-forge` Application |
| Keycloak `OOMKilled` on Z13 | Default memory limits too low for laptop | Increase Keycloak deployment memory request/limit (e.g. 4Gi) or close other workloads; wait for sync to settle |
| HTTPS URLs `connection refused` from browser | envoy-gateway Gateway not programmed / MetalLB / GitOps still syncing | Wait 30–60 min after bootstrap; `kubectl get gateway -n envoy-gateway-system`; ensure MetalLB Application is Synced |
| HTTPS returns **403** or login page never loads | UI pods **Pending** — node has `disk-pressure` taint | Check `kubectl describe node \| grep -E Taints\|DiskPressure` and `df -h /`. Free disk (often Docker build cache: `docker builder prune -a -f && docker system prune -a -f`). Restart RKE2 if taint persists: `sudo systemctl restart rke2-server`. Wait for `keycloak`, `aiwb-ui`, `airm-ui` pods Running, then re-run E2E |

---

## Validation log (Z13, 2026-06-08)

Full Enterprise AI stack validated after phased Bloom install, GitOps workarounds, and `metallb,domain` re-run.

### Changes applied to reach working state

| # | Change | Reason |
|---|--------|--------|
| 1 | `INSTALL_ARGOCD: false` in `bloom-gfx1151.yaml` | Bloom `core-install` ArgoCD vs ClusterForge Helm — immutable selector conflict |
| 2 | `DOMAIN: "192.168.32.13.nip.io"` set before install | `envoy-gateway-config` CoreDNS rewrite; empty domain broke cluster DNS |
| 3 | local-path provisioner for gfx1151 + `NO_DISKS_FOR_CLUSTER` | OpenBao PVC needs `direct` StorageClass (cluster-bloom PR) |
| 4 | `sudo ./bloom cli ... --tags metallb,domain` | MetalLB pool + `cluster-tls` when gateway not on external IP |
| 5 | Ansible tags on `metallb.yaml` / `domain.yaml` tasks | `--tags metallb,domain` previously ran 0 inner tasks |
| 6 | AIWB ArgoCD `targetRevision` → `1.1.9` | `2.0.0-rc.1` chart not published on Docker Hub |
| 7 | AIWB HTTPRoute `parentRefs.namespace` → `envoy-gateway-system` | Chart defaulted to deprecated `kgateway-system` |
| 8 | CoreDNS: domain-scoped rewrite only | Removed broken `.*\.` rule from empty-domain sync |
| 9 | E2E tests: Keycloak OIDC flow (`Sign in with Keycloak` → `devuser@domain`) | NextAuth redirect differs from direct form login |

### Re-validation (2026-06-09)

URLs failed with HTTP **403** because the node accumulated a `node.kubernetes.io/disk-pressure` taint (root FS at 93% — mostly Docker build cache under `/var/lib/docker`). After `docker builder prune -a -f` (~95 GB) + `docker system prune -a -f` (~78 GB) and `sudo systemctl restart rke2-server`, Playwright E2E **3/3 PASS** again.

### Final check results

| Check | Result |
|-------|--------|
| Bloom ClusterForge bootstrap | **PASS** — 27 ok, 0 failed |
| Bloom `--tags metallb,domain` (rebuilt binary) | **PASS** — 3 ok, 4 changed, 0 failed |
| RKE2 node Ready | **PASS** |
| `kubectl get node` GPU capacity | **PASS** — `amd.com/gpu: 1` |
| Gateway programmed + MetalLB | **PASS** — `192.168.32.13:443`, `PROGRAMMED=True` |
| `cluster-tls` + `cluster-domain` | **PASS** — Bloom domain task |
| Keycloak | **PASS** — Synced, Healthy |
| AIRM (`airm` Application) | **PASS** — Synced, Healthy |
| AIWB (`aiwb` Application) | **PASS** — Healthy (OutOfSync after chart/route patches; UI works) |
| HTTPS smoke (`curl`) | **PASS** — aiwbui/airmui/kc return 307 → Keycloak |
| Playwright E2E | **PASS** — 3/3 (`test_aiwb_ui` ×2, `test_airm_ui` ×1) |
| Integration tests | **PARTIAL** — 4/7 pass (GPU scheduling, Kaiwo/AIM operators); Kueue flavor/queue + AIMModel CR need extra ClusterForge config |
| HIP validation | **PASS** — `scripts/validate-hip-gfx1151.sh` |

### Test commands

```bash
# Cluster health
kubectl get applications.argoproj.io -n argocd
kubectl get gateway -n envoy-gateway-system
kubectl get pods -A | grep -vE 'Running|Completed'

# Integration + HIP
pytest tests/integration/ -v
bash scripts/validate-hip-gfx1151.sh

# UI E2E (Keycloak SSO)
python3 -m venv .venv-e2e && .venv-e2e/bin/pip install playwright pytest pytest-playwright
.venv-e2e/bin/playwright install chromium
E2E_AIWB=1 E2E_AIRM=1 .venv-e2e/bin/pytest tests/e2e/test_aiwb_ui.py tests/e2e/test_airm_ui.py -v
```

### Service endpoints (Z13)

| Service | URL | Username |
|---------|-----|----------|
| AI Workbench | `https://aiwbui.192.168.32.13.nip.io` | `devuser@192.168.32.13.nip.io` |
| AIRM | `https://airmui.192.168.32.13.nip.io` | `devuser@192.168.32.13.nip.io` |
| Keycloak admin | `https://kc.192.168.32.13.nip.io` | `silogen-admin` |
| ArgoCD | `https://argocd.192.168.32.13.nip.io` | `admin` |
| Gitea | `https://gitea.192.168.32.13.nip.io` | `gitea_admin` |
| OpenBao | `https://openbao.192.168.32.13.nip.io` | root token (see below) |

Passwords: [Retrieve credentials](#retrieve-credentials).

---

## Retrieve credentials

Kubernetes secrets store values **base64-encoded**. `kubectl get secret <name>` only shows metadata (name, type, key count) — it does **not** print passwords. Use `jsonpath` + `base64 --decode` on the specific key.

Set your domain once (matches `DOMAIN` in `bloom-gfx1151.yaml`):

```bash
NODE_IP=$(hostname -I | awk '{print $1}')
DOMAIN="${NODE_IP}.nip.io"
```

### AI Workbench + AIRM (DevUser)

Both UIs use Keycloak SSO. Click **Sign in with Keycloak**, then log in as `devuser@<domain>`.

```bash
# Username
echo "devuser@${DOMAIN}"

# Password
kubectl -n keycloak get secret airm-realm-credentials \
  -o jsonpath='{.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}' | base64 --decode && echo
```

### Keycloak admin

```bash
# Username: silogen-admin
kubectl -n keycloak get secret keycloak-credentials \
  -o jsonpath='{.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}' | base64 --decode && echo
```

### ArgoCD admin

```bash
# Username: admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode && echo
```

### Gitea admin

```bash
# Username: gitea_admin
kubectl -n gitea get secret gitea-admin-credentials \
  -o jsonpath='{.data.password}' | base64 --decode && echo
```

### OpenBao root token

```bash
kubectl -n openbao get secret openbao-root-token \
  -o jsonpath='{.data.token}' | base64 --decode && echo
```

### List secret keys (without decoding)

```bash
kubectl -n keycloak get secret airm-realm-credentials -o json | jq -r '.data | keys[]'
```

Common keys in `airm-realm-credentials`: `KEYCLOAK_INITIAL_DEVUSER_PASSWORD`, `ADMIN_CLIENT_SECRET`, `ARGOCD_CLIENT_SECRET`, `GITEA_CLIENT_SECRET`, etc. (client secrets for service integration — not UI login passwords).

Bloom also prints these commands in the post-install banner after a successful `bloom cli` run.

Cluster-bloom build checks (`feat/gfx1151-support`):

| Check | Result |
|-------|--------|
| `go test ./pkg/config/...` | Pass (38 schema fields incl. `GPU_GFX1151`) |
| `go build` bloom binary | Pass |
| `metallb` / `domain` tag-filtered run | Pass (after tag fix on child tasks) |

---

## Related docs

- [GFX1151_EAI_DOCS_COMPARISON.md](GFX1151_EAI_DOCS_COMPARISON.md) — official vs local stack comparison
- [CALL_FLOW_OVERVIEW.md](CALL_FLOW_OVERVIEW.md) — inference call flows
- [gfx1151-upstream-pr-guide.md](gfx1151-upstream-pr-guide.md) — patches G1–G9 (incl. amdgpu-dkms root cause)
- [ROCm Radeon/Ryzen](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/) — AMD gfx1151 ROCm guide
