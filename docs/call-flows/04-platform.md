# Call flow: Layer 4 platform (Helm charts)

Components: **cert-manager**, **MetalLB**, **Longhorn**, **Gateway API**, **Kueue**, **KubeRay**, **KServe**.

## cert-manager

- **Down:** Issues TLS Secrets for ingress hostnames (`aiwbui.*`, `airmui.*`).
- **Chat path:** TLS termination before UI/API; no token logic.
- **Up:** Certificate Ready → browser trusts (or self-signed warning).

## MetalLB

- **Down:** Assigns `LoadBalancer` VIP = node IP for Services.
- **Chat path:** External HTTPS to workbench Service IP.
- **Up:** Traffic reaches ingress controller pods.

## Longhorn

- **Down:** PVC provisioner for pod persistent volumes (models, DBs).
- **Chat path:** Storage for **cluster** model caches / DBs — not host GGUF file.
- **Up:** I/O completes to PVC-backed pods.

## Gateway API

- **Down:** HTTPRoute attaches hostnames to backend Services.
- **Chat path:** AIM Engine routing may reference Gateway classes.
- **Up:** 200 from backend routed to client.

## Kueue

- **Down:** Admits KaiwoJobs when quota in `ClusterQueue`.
- **Chat path:** Only for **queued GPU jobs**, not host llama.
- **Up:** Workload admitted → pod created.

## KubeRay / KServe

- Alternative **distributed / model serving** frameworks.
- **Chat path (if used):** InferenceService → predictor pod → GPU.
- **Up:** Prediction response HTTP/gRPC.

## Summary

Platform layer shapes **secure access and storage**; only some charts participate in chat depending on deployment mode. Local Gemma on llama-server minimizes Longhorn/KServe on hot path.
