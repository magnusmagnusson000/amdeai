# Call flow: AMD AI Workbench + AIRM

**Deploy:** `scripts/06b-airm-workbench.sh` (Helm OCI charts)  
**Requires:** `HF_TOKEN` for model catalog features  
**AIM catalog Deploy (gfx1151):** [`docs/AIM_CATALOG_MODEL_DEPLOY_GFX1151.md`](../AIM_CATALOG_MODEL_DEPLOY_GFX1151.md)

## Entry (top of stack)

1. Browser → `https://aiwbui.<DOMAIN>` (TLS via cert-manager + MetalLB).
2. **Keycloak** SSO — click **Sign in with Keycloak**, log in as `devuser@<DOMAIN>` (password: `kubectl -n keycloak get secret airm-realm-credentials -o jsonpath='{.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}' | base64 --decode`).
3. AI Workbench SPA → backend API (authenticated).

## Model resolution

4. User selects model in Chat UI.
5. Backend reads **AIMModel** CR (e.g. `gemma-4-26b-a4b-local`).
6. `spec.endpoint.url` → `http://<node-ip>:8080` (host llama-server).

## Two inference modes

| Mode | Path after resolution |
|------|------------------------|
| **Local registered model** | HTTP to host llama-server (Vulkan or HIP) |
| **Cluster KaiwoJob / vLLM** | Service/Ingress to GPU pod (**standard ROCm HIP**) |

## Response path

7. llama-server or vLLM returns token stream.
8. Workbench backend → UI (SSE/WebSocket).
9. User sees rendered assistant message.

## AIRM

`https://airmui.<DOMAIN>` — GPU inventory, policies. Parallel to chat; not on per-token path for local endpoint.

## Deploy

```bash
HF_TOKEN=... bash scripts/06b-airm-workbench.sh
```
