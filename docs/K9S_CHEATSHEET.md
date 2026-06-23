# k9s cheat sheet — AMD EAI cluster

Quick reference for **k9s** navigation plus the **host-level** start/stop/status commands this repo actually uses. k9s is a read/manage UI on top of `kubectl`; it does **not** start or stop RKE2/k3s — use the shell commands in [Cluster lifecycle](#cluster-lifecycle) for that.

**Related docs:** [`docs/BLOOM_GFX1151_INSTALL.md`](BLOOM_GFX1151_INSTALL.md) (Phase 5 staged startup) · [`docs/call-flows/02-k3s.md`](call-flows/02-k3s.md) (lab k3s path)

---

## Which cluster am I on?

| Path | Control plane | Typical install |
|------|---------------|-----------------|
| **Bloom / gfx1151 (primary)** | `rke2-server` systemd unit | `./bloom cli bloom-gfx1151.yaml` |
| **Lab scripts** | `k3s` systemd unit, or **k3d** cluster `eai` | `bash scripts/02-kubernetes.sh` |

```bash
# One-liner: which runtime is active?
systemctl is-active rke2-server 2>/dev/null || echo "rke2: inactive"
systemctl is-active k3s 2>/dev/null || echo "k3s: inactive"
k3d cluster list 2>/dev/null | grep -E '^NAME|\beai\b' || true

# API reachable?
kubectl get nodes
```

---

## Cluster lifecycle

### Bloom / RKE2 (recommended on Z13)

**Install staged boot once** (creates `amdeai-staged-cluster-startup.service` and `amdeai-cluster-quiesce.service`):

```bash
bash scripts/install-staged-startup-service.sh
```

**Start after reboot or cold boot** (manual equivalent of the systemd unit):

```bash
sudo systemctl start rke2-server
bash scripts/staged-cluster-startup.sh
```

**Resume from phase N** (phases 1–9 in `scripts/config/staged-startup-phases.conf`):

```bash
STAGED_START_PHASE=5 bash scripts/staged-cluster-startup.sh
```

**Trigger staged startup via systemd** (same script as above, runs as your user):

```bash
sudo systemctl start amdeai-staged-cluster-startup.service
```

**Quiesce workloads** (scale heavy Deployments/StatefulSets/InferenceServices to 0; keeps RKE2 running):

```bash
bash scripts/pause-cluster.sh
```

**Stop cluster** (quiesce + stop control plane):

```bash
bash scripts/pause-cluster.sh --stop
# internally: sudo systemctl stop rke2-server || sudo systemctl stop k3s
```

**Restart control plane only** (e.g. clear disk-pressure taint — see BLOOM install troubleshooting):

```bash
sudo systemctl restart rke2-server
```

**Remove staged-boot units:**

```bash
bash scripts/install-staged-startup-service.sh --uninstall
```

**Logs:**

```bash
journalctl -u amdeai-staged-cluster-startup -f
journalctl -u rke2-server -f
tail -f ~/.cache/amdeai/staged-startup.log
sudo systemctl status amdeai-staged-cluster-startup.service
```

**Stuck lock** (staged startup refuses to run):

```bash
rm -f ~/.cache/amdeai/staged-startup.lock
```

**After `--stop`, pods/processes still burning CPU:** `pause-cluster.sh` scales only namespaces in `STAGED_QUIESCE_NAMESPACES` (includes `minio-operator` and `minio-tenant-default`). `systemctl stop rke2-server` can still leave orphaned container PIDs; `--stop` now runs an orphan cleanup pass. If you already stopped manually:

```bash
bash scripts/pause-cluster.sh --stop   # re-run quiesce + stop + orphan kill
# or kill remaining cgroup PIDs only (cluster already stopped):
sudo systemd-cgls /system.slice/rke2-server.service | grep -Eo '[0-9]+' | xargs -r sudo kill -KILL
```

Optional env vars (from `scripts/staged-cluster-startup.sh`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `STAGED_START_PHASE` | `1` | Resume from phase N |
| `STAGED_STARTUP_PAUSE_SEC` | `20` | Pause between phases |
| `STAGED_SKIP_QUIESCE` | `0` | Set `1` to skip scaling workloads to 0 first |
| `STAGED_REENABLE_AUTOSYNC` | `1` | Set `0` to leave ArgoCD manual sync at end |

On **shutdown/reboot**, `amdeai-cluster-quiesce.service` runs `scripts/pause-cluster.sh` automatically (no `--stop` — RKE2 is stopped by the normal shutdown sequence).

### Lab k3s (host install via `02-kubernetes.sh`)

```bash
sudo systemctl start k3s
sudo systemctl stop k3s
sudo systemctl restart k3s
sudo systemctl status k3s
```

Registry smoke test (k3s path only — NodePort **32000**):

```bash
kubectl get svc registry -n kube-system
curl -sf http://localhost:32000/v2/ && echo "registry OK"
```

### Lab k3d (fallback when passwordless sudo is unavailable)

Cluster name is **`eai`** (from `scripts/02-kubernetes.sh`):

```bash
k3d cluster start eai
k3d cluster stop eai
k3d cluster list
```

---

## Status checks (kubectl)

Use these before or alongside k9s. All verified against this repo’s CRDs and scripts.

```bash
# Cluster / node
kubectl get nodes
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:status.capacity.amd\\.com/gpu
kubectl describe node | grep -E 'Taints|DiskPressure'

# Workloads (anything not Running/Completed)
kubectl get pods -A | grep -vE 'Running|Completed'

# GitOps (Bloom)
kubectl get application -n argocd
kubectl get application -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# Ingress / TLS gateway
kubectl get gateway -n envoy-gateway-system

# AIM inference
kubectl get aimservice -A
kubectl get inferenceservice -A
kubectl get aimclusterprofile

# Pause inference only (keeps CRs and PVCs)
bash scripts/pause-aim-inference.sh demo
bash scripts/pause-aim-inference.sh demo wb-aim-0423d652
```

After staged startup completes, **inference stays paused** until you deploy from AI Workbench or scale InferenceServices back up.

---

## Launch k9s

```bash
k9s                          # default view (uses $KUBECONFIG or ~/.kube/config)
k9s -A                       # all namespaces
k9s -n argocd                # start scoped to one namespace
k9s -n argocd -c applications   # jump straight to a resource view
k9s --readonly               # view-only (no edit/delete)
k9s info                     # config paths, active context
```

Press **`?`** inside k9s for the full key map (k9s v0.51+).

---

## k9s navigation (essential keys)

| Action | Key |
|--------|-----|
| Command prompt (go to resource) | `:` then resource name, Enter |
| Filter rows | `/` then regex, Enter |
| Filter by labels | `/-l app=foo,env=dev` |
| All namespaces | `ctrl-a` (or launch with `k9s -A`) |
| Switch namespace | `:ns` |
| Switch context | `:ctx` |
| Back | `esc` |
| Describe | `d` |
| YAML | `y` |
| Logs | `l` (previous: `p`) |
| Shell into pod | `s` |
| Port-forward | `shift-f` |
| Delete (confirm) | `ctrl-d` |
| Kill pod (no confirm) | `ctrl-k` |
| Restart Deployment/STS/DS | `r` |
| Copy resource name | `c` |
| Refresh | `ctrl-r` |
| Quit | `:q` or `ctrl-c` |

Colon commands accept **singular, plural, or short names** — e.g. `:pod`, `:pods`, `:po`.

---

## Resource views for this stack

Type at the `:` prompt (add a namespace after a space when needed).

| What you want | k9s command | Namespace |
|---------------|-------------|-----------|
| Nodes / GPU capacity | `:nodes` | — |
| All pods | `:pods` or `k9s -A -c pods` | — |
| ArgoCD apps | `:applications` or `:app` | `argocd` |
| Gateway (HTTPS) | `:gateways` or `:gtw` | `envoy-gateway-system` |
| Keycloak | `:deploy` | `keycloak` |
| AI Workbench | `:deploy` | `aiwb` |
| AIRM | `:deploy` | `airm` |
| AIM operator | `:pods` | `aim-system` |
| AIM services | `:aimservices` or `:aimsvc` | `demo`, `default` |
| KServe predictors | `:inferenceservices` or `:isvc` | `demo`, `default` |
| Cluster profiles | `:aimclusterprofiles` or `:aimclprf` | `default` |
| GPU device plugin | `:ds` (DaemonSet) | `kube-system` |
| Evicted / bad pods | `:pods` then `/Evicted` or `/Error` | — |

**Filtered examples:**

```text
:pods aiwb              # pods in namespace aiwb
:pods /keycloak         # pods matching "keycloak" (all namespaces if -A)
:app /OutOfSync         # ArgoCD apps not synced
:aimsvc demo            # AIMService in demo
```

**XRay** (dependency graph): `:xray po aiwb` or `:xray svc demo`

---

## Common workflows in k9s

### 1. “Is the cluster up?”

1. Shell: `kubectl get nodes` — expect `Ready`.
2. k9s: `:nodes` — check STATUS and GPU column (toggle wide: `ctrl-w`).
3. Bloom: `:gateways envoy-gateway-system` — `PROGRAMMED` should be `True`.

### 2. “Why is HTTPS broken?”

1. `:app argocd` — sort by sync/health (`shift-s`); look for `OutOfSync` / `Degraded`.
2. `:pods keycloak` — Keycloak must be `Running` (OOM → see staged startup in BLOOM doc).
3. `:pods aiwb` — `aiwb-ui` / backend pods Running.
4. Shell: `kubectl describe node | grep -E Taints|DiskPressure` if pods are Pending.

### 3. “What is using the GPU?”

1. `:isvc demo` and `:isvc default` — predictor pods.
2. `:pods demo` then `/predictor`.
3. Shell: `bash scripts/pause-aim-inference.sh demo` to free GPU without deleting models.

### 4. “Tail logs during staged startup”

Keep a terminal on `tail -f ~/.cache/amdeai/staged-startup.log`, use k9s `:app argocd` to watch apps flip to `Synced`/`Healthy` phase by phase.

---

## k9s vs shell — when to use which

| Task | Use |
|------|-----|
| Start/stop RKE2 or k3s | **shell** (`systemctl`, `pause-cluster.sh`) |
| Staged ArgoCD bring-up | **shell** (`staged-cluster-startup.sh`) |
| Browse pods, logs, YAML | **k9s** |
| Patch CRs / emergency scale | **shell** (repo scripts) or k9s `e` / `ctrl-d` |
| Free GPU, keep AIM CRs | **shell** (`pause-aim-inference.sh`) |

---

## References

- k9s project: [github.com/derailed/k9s](https://github.com/derailed/k9s) (key bindings verified against v0.51.0)
- Staged startup phases: `scripts/config/staged-startup-phases.conf`
- Pause/quiesce implementation: `scripts/pause-cluster.sh`, `scripts/lib/staged-startup.sh`
