# AIM Engine — Deep Dive

**Project:** [amd-enterprise-ai/aim-engine](https://github.com/amd-enterprise-ai/aim-engine)  
**Current version:** v0.2.4 (2026-05-26)  
**Namespace:** `aim-system`  
**Install script:** `scripts/06a-aim-engine.sh`  
**Call flow:** [call-flows/06a-aim-engine.md](call-flows/06a-aim-engine.md)

---

## 1. What AIM Engine Is

AIM Engine (AMD Inference Microservices Engine) is a Kubernetes operator that manages the full lifecycle of AI inference workloads on AMD hardware. It sits at Layer 6 of the Enterprise AI stack, between workload orchestration (Kaiwo/Kueue) and the user-facing UI (AI Workbench).

Its job is to bridge the gap between a model artifact and a production-ready inference HTTP endpoint. You give it an AIM container image; it handles model discovery, weight downloading, KServe InferenceService creation, Gateway API routing, and autoscaling.

The operator watches a set of Custom Resource Definitions (CRDs). Users declare *what* they want (model + service configuration); the operator figures out *how* to run it.

---

## 2. Repository Structure

```
aim-engine/
├── api/
│   └── v1alpha1/           # Go type definitions for all CRDs
│       ├── aimmodel_types.go
│       ├── aimmodel_shared.go
│       ├── aimservice_types.go
│       └── ...
├── internal/
│   └── v1alpha1/
│       ├── controller/     # controller-runtime reconcile loops
│       ├── aimservice/     # AIMService reconciliation logic
│       ├── aimservicetemplate/  # template discovery + selection
│       ├── aimartifact/    # model weight download management
│       └── ...
├── dist/
│   ├── crds.yaml           # generated CRD manifests (apply first)
│   └── chart/              # generated Helm chart
├── docs/                   # upstream documentation (concepts, guides, reference)
└── tests/
    └── e2e/                # chainsaw end-to-end tests
```

Built with [controller-runtime](https://github.com/kubernetes-sigs/controller-runtime) using the standard Kubernetes operator pattern: watch → reconcile → update status.

---

## 3. CRD Inventory

All CRDs live under the API group `aim.eai.amd.com`.

| CRD | Version | Scope | Purpose |
|-----|---------|-------|---------|
| `AIMService` | v1alpha1 | Namespace | Primary resource — deploys a model as an inference endpoint |
| `AIMModel` | v1alpha1 | Namespace | Maps a model name to an image; catalog entry |
| `AIMClusterModel` | v1alpha1 | Cluster | Cluster-wide model catalog entry |
| `AIMProfile` | v1alpha2 | Namespace | Self-contained runtime config (new, replaces templates) |
| `AIMClusterProfile` | v1alpha2 | Cluster | Cluster-wide profile |
| `AIMServiceTemplate` | v1alpha1 | Namespace | Runtime profile — **deprecated, use Profiles** |
| `AIMClusterServiceTemplate` | v1alpha1 | Cluster | Cluster-wide runtime profile — **deprecated** |
| `AIMRuntimeConfig` | v1alpha1 | Namespace | Namespace-level storage and routing defaults |
| `AIMClusterRuntimeConfig` | v1alpha1 | Cluster | Cluster-wide storage and routing defaults |
| `AIMClusterModelSource` | v1alpha1 | Cluster | Discovers model images from container registries |
| `AIMArtifact` | v1alpha1 | Namespace | Manages model weight download to a PVC |
| `AIMTemplateCache` | v1alpha1 | Namespace | Groups AIMArtifacts for a template; controls caching mode |
| `AIMProfileCache` | v1alpha1 | Namespace | Caching for v1alpha2 Profiles |
| `AIMClusterRuntimeConfig` | v1alpha1 | Cluster | Cluster-wide routing and defaults |

### Cluster vs Namespace scoping

Several CRDs exist in both cluster and namespace variants. Resolution order is always **namespace wins over cluster**. RuntimeConfig is special: both are **merged** if both exist, with namespace values overriding matching fields.

---

## 4. Core Concepts

### 4.1 AIMModel / AIMClusterModel

An `AIMModel` is a catalog entry that maps a model name to a container image. The operator inspects that image to:

- Extract metadata labels (`com.amd.aim.model.canonicalName`, `com.amd.aim.model.deployments`)
- Auto-create `AIMServiceTemplate` / `AIMClusterServiceTemplate` resources (v1alpha1) or `AIMProfile` / `AIMClusterProfile` (v1alpha2) based on the image's recommended deployments

The `metadata.name` is the canonical model identifier used by `AIMService.spec.model.name`.

**Key spec fields:**

| Field | Purpose |
|-------|---------|
| `image` | Container image URI (required unless `aimId` + dynamic version policy) |
| `aimId` | Model family ID for fine-tuned model template matching (v0.2.4+) |
| `discovery.extractMetadata` | Whether to connect to the registry and read image labels |
| `discovery.createServiceTemplates` | Whether to auto-create templates from extracted metadata |
| `modelSources` | Explicit HuggingFace/S3 artifact sources (custom weight deployment) |
| `custom.hardware` | Hardware requirements when `modelSources` is set without `aimId` |
| `imageMetadata` | Override/bypass remote extraction when registry is unreachable |

**Status conditions:**

| Condition | Meaning |
|-----------|---------|
| `RuntimeConfigReady` | Runtime config resolved successfully |
| `ImageMetadataReady` | Image labels extracted (or skipped) |
| `ServiceTemplatesReady` | Auto-generated templates are healthy |
| `Ready` | All components ready |

### 4.2 AIMService

The primary deployment resource. Creates a managed KServe `InferenceService` backed by an AIM container image.

**Reconciliation pipeline:**

```
1. Fetch    → resolve model, template/profile, runtime config
2. Compose  → interpret health state, check availability
3. Plan     → decide what Kubernetes objects to create or update
4. Apply    → execute changes
5. Status   → update conditions and health
```

**Model resolution modes:**

| Mode | Field | Behaviour |
|------|-------|-----------|
| Reference | `spec.model.name` | Looks up existing AIMModel by name (namespace first, then cluster) |
| Image URI | `spec.model.image` | Finds or creates matching AIMModel; creates one if none exist |
| Custom | `spec.model.custom` | Inline `modelSources` + hardware requirements; creates a namespaced AIMModel |

**Template auto-selection algorithm (v1alpha1):**

1. Filter to `Ready` templates only
2. Exclude `unoptimized` unless `spec.template.allowUnoptimized: true`
3. Filter to templates whose required GPU is present in the cluster (via node labels)
4. Namespace-scoped templates take precedence over cluster-scoped
5. Score remaining by: profile type > GPU tier > metric > precision

**Status values:** `Pending` → `Starting` → `Running` (or `Failed` / `Degraded`)

### 4.3 AIMProfile / AIMClusterProfile (v1alpha2)

The successor to ServiceTemplates. A profile is fully self-contained — it carries the accelerator requirements, resource requests, engine arguments, and container image without referencing any other resource.

Key fields: `aimId`, `acceleratorModel`, `acceleratorType`, `acceleratorCount`, `metric`, `precision`, `type`, `image`, `engineArgs`, `engineEnv`, `modelSources`.

Profiles are the preferred configuration unit for new deployments. AIMService v1alpha2 (using `spec.profile` instead of `spec.template`) is the migration target.

### 4.4 AIMClusterModelSource

Discovers AIM container images from registries on a schedule and creates `AIMClusterModel` resources automatically. Configured with a `filters` list of image URIs, a `registry`, `maxModels`, and `syncInterval`.

This is how the model catalog is populated in this repo — see `~/eai-build/cluster-forge/sources/aim-cluster-model-source/aim-models-0.11.0.yaml`.

### 4.5 Model Caching (AIMArtifact + AIMTemplateCache)

Model weights are always downloaded to a PVC before inference starts. The caching system avoids re-downloading across restarts and between services sharing the same model.

```
AIMTemplateCache (Shared or Dedicated)
  └── AIMArtifact(s)
        └── PVC + Download Job
```

**Shared mode** (default): PVCs are unowned and persist independently. Multiple services using the same template share one PVC download.

**Dedicated mode**: PVCs are owned by the cache and garbage-collected when the service is deleted.

Caching supports storage quota enforcement with priority-based eviction: lowest `retentionPriority` artifacts are evicted first when quota is exceeded.

### 4.6 AIMRuntimeConfig / AIMClusterRuntimeConfig

Provides cluster or namespace-level defaults for: storage class, routing (Gateway ref + path template + request timeout), environment variables, image pull secrets, and artifact storage quota.

When both namespace and cluster configs exist, they are **merged** (namespace values win). This makes `AIMClusterRuntimeConfig` the right place for cluster-wide routing defaults and `AIMRuntimeConfig` for per-team overrides.

---

## 5. Infrastructure Dependencies

| Dependency | Purpose in AIM |
|------------|---------------|
| **KServe** (v0.16.1+) | Creates and manages `InferenceService` resources — the actual serving runtime |
| **Gateway API** (v1.3.0+) | HTTPRoute creation to expose endpoints through a Gateway |
| **AMD GPU Operator** | Publishes `amd.com/gpu` and `feature.node.kubernetes.io/aim-accelerator.*` node labels used for template selection |
| **KEDA** (2.18+) | Autoscaling via OpenTelemetry metrics from vLLM |
| **OpenTelemetry Operator** | Custom metric collection for KEDA |
| **ReadWriteMany CSI** (e.g. Longhorn) | Shared PVCs for model weight caching |
| **Node Feature Discovery (NFD)** | AcceleratorDetector DaemonSets write hardware labels via NFD |

---

## 6. AcceleratorDetector

Two DaemonSets (`aim-base` for GPU nodes, `aim-epyc-base` for CPU nodes) run `aim-runtime detect-hardware` on every node. Results are written to NFD feature files and published as node labels:

```
feature.node.kubernetes.io/aim-accelerator.MI300X: "8"
feature.node.kubernetes.io/aim-accelerator.EPYC_9965: "128"
```

AIM Engine uses these labels for node affinity in template selection without hardcoding hardware specifics. The AcceleratorDetector runs every 5 minutes by default and is enabled via `acceleratorDetector.enable: true` in Helm values.

**On gfx1151 (Strix Halo):** The `aim-accelerator` labels are not published because the AcceleratorDetector targets Instinct MI-series GPUs. Template selection falls back to `amd.com/gpu.device-id` labels from the k8s-device-plugin.

---

## 7. AIM Container Image Format

An official AIM image (e.g. `amdenterpriseai/aim-qwen-qwen3-32b:0.11.0`) is an OCI image built on `amdenterpriseai/aim-base`. It encodes its deployment recommendations in image labels:

```
com.amd.aim.model.canonicalName   = qwen/qwen3-32b
com.amd.aim.model.deployments     = <JSON: array of recommended deployment configs>
```

Each deployment config in the JSON becomes one `AIMServiceTemplate` or `AIMClusterProfile` after discovery. The config specifies: GPU model, count, precision, metric, engine args, and `modelSources` (HuggingFace URIs).

The image itself does **not** contain the model weights. Weights are downloaded at deployment time by an `AIMArtifact` download job into a PVC.

**Container image catalog (v0.11.0):**

| Image | Model |
|-------|-------|
| `aim-google-gemma-3-27b-it:0.11.0` | google/gemma-3-27b-it |
| `aim-meta-llama-llama-3-3-70b-instruct:0.11.0` | meta-llama/Llama-3.3-70B-Instruct |
| `aim-meta-llama-llama-3-1-405b-instruct:0.11.0` | meta-llama/Llama-3.1-405B-Instruct |
| `aim-deepseek-ai-deepseek-r1:0.11.0` | deepseek-ai/DeepSeek-R1 |
| `aim-deepseek-ai-deepseek-v3-1:0.11.0` | deepseek-ai/DeepSeek-V3.1 |
| `aim-qwen-qwen3-32b:0.11.0` | qwen/qwen3-32b |
| `aim-qwen-qwen3-235b-a22b:0.11.0` | qwen/qwen3-235b-a22b (MoE) |
| `aim-openai-gpt-oss-120b:0.11.0` | openai/gpt-oss-120b |
| `aim-mistralai-mixtral-8x22b-instruct-v0-1:0.11.0` | mistralai/Mixtral-8x22B |

Full list: `~/eai-build/cluster-forge/sources/aim-cluster-model-source/aim-models-0.11.0.yaml`

---

## 8. Deployment Patterns

### 8.1 Managed in-cluster service (standard path)

Requires: GPU nodes, KServe, Gateway API, ReadWriteMany storage.

```yaml
# Step 1: Ensure model is in catalog (via AIMClusterModelSource or manual)
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMClusterModel
metadata:
  name: qwen-qwen3-32b
spec:
  image: amdenterpriseai/aim-qwen-qwen3-32b:0.11.0

---
# Step 2: Deploy service
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMService
metadata:
  name: qwen-chat
  namespace: default
spec:
  model:
    name: qwen-qwen3-32b
  caching:
    mode: Shared
  replicas: 1
```

The operator then: runs discovery on the model image → auto-creates templates → downloads weights to PVC → creates KServe InferenceService → creates HTTPRoute.

Progress: `kubectl get aimservice qwen-chat -w`

### 8.2 Custom weights (fine-tuned or GGUF-style)

```yaml
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMService
metadata:
  name: my-finetuned-model
  namespace: default
spec:
  model:
    custom:
      baseImage: amdenterpriseai/aim-base:0.11.0
      modelSources:
        - modelId: my-org/my-model
          sourceUri: hf://my-org/my-model
      hardware:
        gpu:
          requests: 1
  template:
    allowUnoptimized: true
  caching:
    mode: Dedicated
```

### 8.3 Fine-tuned model matching (v0.2.4+)

```yaml
# AIMModel with aimId — controller finds matching official templates automatically
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMModel
metadata:
  name: my-qwen3-finetuned
  namespace: default
spec:
  aimId: qwen/qwen3-32b
  custom:
    versionPolicy: latest
  modelSources:
    - modelId: my-org/qwen3-finetuned
      sourceUri: hf://my-org/qwen3-32b-finetuned
```

The controller finds templates for `qwen/qwen3-32b`, filters by version policy, and creates copies pointing at the custom weights.

### 8.4 External endpoint registration (host llama-server — this repo's pattern)

AIM Engine v0.2.x removed the old `spec.endpoint` field. Register a host `llama-server` with a Service/Endpoints bridge:

```bash
MY_IP=$(hostname -I | awk '{print $1}')

# 1. Bridge cluster → host
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: gemma-4-31b-local
  namespace: default
spec:
  ports:
  - name: http
    port: 8081
    targetPort: 8081
---
apiVersion: v1
kind: Endpoints
metadata:
  name: gemma-4-31b-local
  namespace: default
subsets:
- addresses:
  - ip: ${MY_IP}
  ports:
  - name: http
    port: 8081
EOF

# 2. AIMModel catalog stub
kubectl apply -f - <<EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMModel
metadata:
  name: gemma-4-31b-local
  namespace: default
  annotations:
    aim.eai.amd.com/external-endpoint: "http://${MY_IP}:8081"
    aim.eai.amd.com/display-name: "Gemma 4 31B (local Q4_K_M)"
    aim.eai.amd.com/model-id: "gemma-4-31b"
spec:
  image: amdenterpriseai/aim-base:0.11.0
  discovery:
    extractMetadata: false
    createServiceTemplates: false
EOF
```

The AIMModel becomes `Ready` immediately. No pods spawned. AIWB resolves the endpoint URL via the Service name.

---

## 9. Gateway Routing

When `AIMClusterRuntimeConfig.spec.routing.enabled: true`, the operator creates an `HTTPRoute` for every `AIMService`. This cluster's runtime config (`aiwb` namespace):

```yaml
spec:
  routing:
    enabled: true
    gatewayRef:
      kind: Gateway
      name: https
      namespace: kgateway-system
    pathTemplate: '{.metadata.namespace}/{.metadata.labels[''airm.silogen.ai/workload-id'']}'
    requestTimeout: 30m
```

Paths are built by evaluating the JSONPath template against the service's metadata. Custom path templates can use any metadata field or label.

---

## 10. Autoscaling

AIMService integrates with KEDA for metric-driven autoscaling:

```yaml
spec:
  minReplicas: 1
  maxReplicas: 5
  autoScaling:
    metrics:
      - type: PodMetric
        podmetric:
          metric:
            backend: opentelemetry
            metricNames:
              - vllm:num_requests_running
            query: "vllm:num_requests_running"
            operationOverTime: avg
          target:
            type: Value
            value: "1"
```

Common vLLM metrics: `vllm:num_requests_running`, `vllm:num_requests_waiting`.

KEDA creates a `ScaledObject` → manages an HPA → scales the KServe deployment.

---

## 11. gfx1151 (Strix Halo) Limitations

| Limitation | Detail |
|------------|--------|
| No official AIM container for Gemma 4 | `aim-models-0.11.0.yaml` only has `aim-google-gemma-3-27b-it`; no Gemma 4 image |
| AcceleratorDetector does not label gfx1151 | Targets MI-series Instinct GPUs only; gfx1151 is RDNA 3.5 APU |
| Managed AIMService path blocked | Requires KServe template selection to match gfx1151; no profiles for this GPU in catalog |
| **Workaround** | Host `llama-server` + Service/Endpoints + AIMModel stub (see §8.4 above, `scripts/07-llama-cpp.sh`, `scripts/08-gemma4-31b.sh`) |

When AMD releases `amdenterpriseai/aim-google-gemma-4-31b-it`, add it to `aim-models-0.11.0.yaml` under `filters` and bump the `AIMClusterModelSource` name to trigger re-sync.

---

## 12. Installation in This Repo

### Cluster Bloom path (primary)

Bloom installs AIM Engine via ArgoCD from `~/eai-build/cluster-forge/sources/aim-engine/0.2.2/` and CRDs from `sources/aim-engine-crds/0.2.2/`.

### k3s script path

`scripts/06a-aim-engine.sh` builds from source:

```bash
ensure_git_repo https://github.com/amd-enterprise-ai/aim-engine.git \
  "$EAI_BUILD_DIR/aim-engine" main
cd "$EAI_BUILD_DIR/aim-engine"
make crds   # → dist/crds.yaml
make helm   # → dist/chart/
kubectl apply -f dist/crds.yaml
helm install aim-engine dist/chart/ \
  --namespace aim-system --create-namespace \
  --set clusterRuntimeConfig.enable=true \
  --set clusterRuntimeConfig.spec.routing.enabled=true
```

### Verify

```bash
kubectl get pods -n aim-system
kubectl get crd | grep aim
kubectl get aimclustermodels | head -5
```

---

## 13. Observability

```bash
# Operator logs
kubectl logs -n aim-system deploy/aim-engine-controller-manager -f

# AIMModel status
kubectl describe aimmodel gemma-4-31b-local

# AIMService conditions
kubectl get aimservice <name> -o jsonpath='{.status.conditions}' | jq

# Model catalog
kubectl get aimclustermodels

# Services
kubectl get aimservices -A

# Template/profile auto-selection result
kubectl get aimservice <name> -o jsonpath='{.status.resolvedModel.scope}'
```

---

## 14. Related Docs

| Document | Contents |
|----------|----------|
| [call-flows/06a-aim-engine.md](call-flows/06a-aim-engine.md) | Call flow for AIM Engine in this stack |
| [call-flows/07-llama-cpp.md](call-flows/07-llama-cpp.md) | Host llama-server + AIMModel pattern |
| [call-flows/08-gemma4-31b.md](call-flows/08-gemma4-31b.md) | Gemma 4 31B AIMModel registration |
| [OVERVIEW.md](OVERVIEW.md) | Full stack layer diagram |
| [CALL_FLOW_OVERVIEW.md](CALL_FLOW_OVERVIEW.md) | End-to-end call flow diagrams |
| Upstream repo | [github.com/amd-enterprise-ai/aim-engine](https://github.com/amd-enterprise-ai/aim-engine) |
| Upstream docs | `~/eai-build/aim-engine/docs/` |
