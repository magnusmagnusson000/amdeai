# Call flow: Layer 4 platform (Helm charts)

**Script:** `scripts/04-platform.sh`

Components: **cert-manager**, **MetalLB**, **Longhorn**, **Gateway API**, **Kueue**, **KubeRay**, **KServe**.

## Role in EAI suite

Platform charts provide **TLS, networking, storage, and queuing** for cluster services. They enable AI Workbench HTTPS URLs and Kaiwo job admission.

## Per-component summary

| Chart | Down (request) | Chat path |
|-------|----------------|-----------|
| **cert-manager** | TLS Secrets for ingress | HTTPS to AIWB/AIRM |
| **MetalLB** | LoadBalancer VIP = node IP | External access to UIs |
| **Longhorn** | PVCs for pod storage | Model caches, DBs in cluster |
| **Gateway API** | HTTPRoute → backends | AIM routing (if enabled) |
| **Kueue** | Admits KaiwoJobs | **Standard GPU job path** |
| **KubeRay / KServe** | Ray / InferenceService | Alternative serving |

## Standard inference interaction

```
User → MetalLB/TLS → AIWB → (optional) KaiwoJob → Kueue admit → GPU pod
```

Local Gemma via host llama-server **minimizes** Longhorn/KServe on the token hot path but platform charts remain required for Workbench UI.

## Deploy

```bash
bash scripts/04-platform.sh
```

Force reinstall is default (`EAI_FORCE_REBUILD=1`).
