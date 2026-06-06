# Call flow: silogen/cluster-forge

**Source:** `~/eai-build/cluster-forge/`  
**Script:** `scripts/05a-cluster-forge.sh`

GitOps **installer** — deploy-time only; not on inference hot path after bootstrap.

## Workflow

```bash
cd ~/eai-build/cluster-forge
go run . smelt    # config.yaml → working/
go run . cast     # package OCI artefact
./scripts/bootstrap.sh <domain> --cluster-size=small \
  --disabled-apps=airm,keycloak,cnpg,minio
```

**This stack:** AIRM/Keycloak deployed separately via `06b-airm-workbench.sh`; domain = `<node-ip>.nip.io`.

## What gets installed

- ArgoCD, Gitea, OpenBao (secrets)
- References to Kaiwo, platform charts, AIM Engine (via app-of-apps)

## Chat prompt path

**None at inference time.** Shapes **what is installed** (operators, GitOps UI).

## Upward

- ArgoCD sync status: `kubectl get applications -n argocd`
- Gitea at `https://gitea.<IP>.nip.io`
