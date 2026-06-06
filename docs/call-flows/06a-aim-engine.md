# Call flow: amd-enterprise-ai/aim-engine

**Source:** `~/eai-build/aim-engine/`  
**Script:** `scripts/06a-aim-engine.sh`

Kubernetes operator for **AIMModel** CRs and routing — control plane adjacent to chat.

## Downward

1. Helm installs CRDs + controller manager.
2. **AIMModel** CR registers inference endpoints (URL, OpenAI type, capabilities).
3. For external host endpoints (`http://<node-ip>:8080`), operator **registers** only — no pod spawn.

## Chat path (local Gemma)

1. AI Workbench resolves model name → reads **AIMModel** CR.
2. Backend POSTs to `spec.endpoint.url` (host llama-server).
3. AIM Engine is **not** in the per-token loop unless Gateway routing is enabled for in-cluster backends.

## Upward

- `kubectl describe aimmodel gemma-4-26b-a4b-local`
- Status conditions: Ready, observed generation

## Standard vs local

| Mode | AIM Engine role |
|------|-----------------|
| Cluster vLLM | May configure Gateway routes to Service |
| Host llama-server | CR registration + URL lookup only |
