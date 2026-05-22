# AMD Enterprise AI Suite — Build From Source Guide
## Asus Z13 · Radeon 8060S (gfx1151) · 128 GB RAM · Ubuntu 24.04

> **Last updated:** May 2026  
> **Hardware:** AMD Radeon 8060S (RDNA 3.5, gfx1151, 40 CUs), 128 GB LPDDR5x-8000 unified memory, 256 GB/s bandwidth  
> **Model in use:** `gemma-4-26b-a4b-it-Q4_K_M.gguf` (already downloaded)

---

## Disk Space Requirements

| Component | Runtime on disk | Notes |
|---|---|---|
| ROCm 7.2.3 (packages) | ~18 GB | Installed from AMD repo |
| Go 1.23 toolchain | ~500 MB | Used by cluster-forge, kaiwo, aim-engine |
| llama.cpp source + Vulkan build | ~2.5 GB | Vulkan backend only |
| k3s + containerd image cache | ~9 GB | Single binary + system images |
| Cert-Manager, MetalLB, Longhorn (Helm) | ~3 GB | Longhorn replica on local disk |
| cluster-forge source + build | ~700 MB | Deploys then is not resident |
| kaiwo source + build | ~700 MB | Operator image in local registry |
| AIM Engine source + build | ~1.2 GB | Helm chart + operator image |
| AMD Resource Manager + AI Workbench | ~4 GB | Pre-built OCI images |
| KServe, Ray Operator, Kueue | ~2 GB | Deployed via Helm |
| Gemma 4 26B-A4B Q4_K_M GGUF | ~14 GB | Your existing weights |
| Container image cache (inference) | ~12 GB | vLLM Navi image + adapted AIM |
| **Total** | **~65–75 GB** | Plus OS, logs, Longhorn growth |

> ⚠️ **Recommended minimum free space before starting: 100 GB.**  
> Create a dedicated data partition of at least 80 GB for `/var/lib/rancher` (Kubernetes workloads, Longhorn, model cache).

---

## Architecture

Seven layers, built in order:

```
Layer 1: Host        — ROCm 7.2.3 + kernel boot params
Layer 2: Kubernetes  — k3s single-node cluster + local registry
Layer 3: GPU sched.  — AMD k8s-device-plugin (source build)
Layer 4: Platform    — cert-manager, MetalLB, Longhorn, KServe, Kueue, Ray (Helm)
Layer 5: Orchestr.   — cluster-forge + kaiwo (source build)
Layer 6: AI services — AIM Engine (source build) + AIRM + Workbench (Helm)
Layer 7: Inference   — llama.cpp Vulkan serving Gemma 4 26B-A4B
```

---

## Prerequisites — Build Toolchain

Install all build dependencies first.

```bash
sudo apt update && sudo apt upgrade -y

sudo apt install -y \
  git curl wget build-essential cmake ninja-build \
  python3-pip python3-venv python3-dev \
  pkg-config libssl-dev zlib1g-dev \
  glslang-tools libvulkan-dev vulkan-tools

# Go 1.23
wget https://go.dev/dl/go1.23.8.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.23.8.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.bashrc
echo 'export GOPATH=$HOME/go' >> ~/.bashrc
source ~/.bashrc
go version   # Verify: go1.23.8

# Helm 3
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

# devbox (required for cluster-forge development shell)
curl -fsSL https://get.jetpack.io/devbox | bash
```

---

## Layer 1 — Host: ROCm 7.2.3 + Kernel Parameters

### 1.1 — HWE Kernel

```bash
sudo apt install -y linux-oem-24.04d
sudo reboot
uname -r   # Verify: 6.14.x or newer
```

### 1.2 — Kernel Boot Parameters

> Without these, the GPU memory pool is exposed as ~512 MB instead of 128 GB.

```bash
sudo nano /etc/default/grub
# Append to GRUB_CMDLINE_LINUX_DEFAULT:
# amd_iommu=off amdgpu.gttsize=131072 ttm.pages_limit=33554432

sudo update-grub
sudo reboot
```

### 1.3 — ROCm 7.2.3

```bash
sudo mkdir --parents --mode=0755 /etc/apt/keyrings
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

sudo tee /etc/apt/sources.list.d/rocm.list << 'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.3 noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/7.2.3/ubuntu noble main
EOF

sudo tee /etc/apt/preferences.d/rocm-pin-600 << 'EOF'
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

sudo apt update && sudo apt install -y rocm
sudo usermod -aG render,video $USER
sudo reboot
```

### 1.4 — Verify and Apply gfx1151 Override

```bash
rocminfo | grep -E "Name|gfx|Marketing"
rocm-smi --showmeminfo vram   # Must show ~128 GiB

# Persistent GFX override — required for all ROCm tools and containers
echo 'HSA_OVERRIDE_GFX_VERSION=11.5.1' | sudo tee -a /etc/environment
echo 'PYTORCH_TUNABLEOP_ENABLED=1' | sudo tee -a /etc/environment
echo 'TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1' | sudo tee -a /etc/environment
source /etc/environment
```

---

## Layer 2 — Kubernetes: k3s Single-Node Cluster

### 2.1 — Prepare Dedicated Storage Partition

Kubernetes workloads need a dedicated path. Check your layout and create a partition:

```bash
lsblk
# Identify your NVMe: typically /dev/nvme0n1
# If you have 80+ GB free, create a new partition:

sudo fdisk /dev/nvme0n1
# Press: n (new), p (primary), accept defaults for size, w (write)

# Format and mount (replace X with your new partition number)
sudo mkfs.ext4 /dev/nvme0n1pX
sudo mkdir -p /var/lib/rancher
sudo mount /dev/nvme0n1pX /var/lib/rancher

# Persist across reboots
echo "UUID=$(blkid -s UUID -o value /dev/nvme0n1pX) /var/lib/rancher ext4 defaults 0 2" | \
  sudo tee -a /etc/fstab
```

> If no free partition is available, k3s will use `/var/lib/rancher` on your root disk. It works but watch disk usage.

### 2.2 — Disable Swap

```bash
sudo swapoff -a
sudo sed -i 's/^\(.*swap.*\)$/#\1/' /etc/fstab
```

### 2.3 — Install k3s

```bash
export MY_IP=$(hostname -I | awk '{print $1}')

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --node-ip=${MY_IP} \
  --tls-san=${MY_IP} \
  --disable=traefik \
  --disable=servicelb \
  --kubelet-arg=--allowed-unsafe-sysctls=net.* \
  --kube-apiserver-arg=allow-privileged=true" sh -

# Wait for k3s to become ready (~60s)
sudo kubectl get nodes   # Should show: Ready

# Set up kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
sed -i "s/127.0.0.1/${MY_IP}/g" ~/.kube/config
export KUBECONFIG=~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
```

### 2.4 — Deploy Local Container Registry

You will push custom-built images here.

```bash
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: registry}
  template:
    metadata:
      labels: {app: registry}
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: data
          mountPath: /var/lib/registry
      volumes:
      - name: data
        hostPath:
          path: /var/lib/rancher/registry-data
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: kube-system
spec:
  type: NodePort
  selector: {app: registry}
  ports:
  - port: 5000
    targetPort: 5000
    nodePort: 32000
EOF

# Trust the local registry in k3s/containerd
sudo tee /etc/rancher/k3s/registries.yaml << EOF
mirrors:
  "localhost:32000":
    endpoint:
      - "http://localhost:32000"
  "${MY_IP}:32000":
    endpoint:
      - "http://${MY_IP}:32000"
EOF

sudo systemctl restart k3s
sleep 30
kubectl get pods -n kube-system | grep registry
```

---

## Layer 3 — GPU Scheduling: AMD k8s-device-plugin (Source Build)

This DaemonSet exposes `amd.com/gpu: 1` as a schedulable Kubernetes resource.

### 3.1 — Clone and Build

```bash
mkdir -p ~/eai-build && cd ~/eai-build
git clone https://github.com/ROCm/k8s-device-plugin.git
cd k8s-device-plugin

docker build -t localhost:32000/amd-gpu-device-plugin:latest .
docker push localhost:32000/amd-gpu-device-plugin:latest
```

### 3.2 — Deploy with gfx1151 Override

The upstream YAML does not pass `HSA_OVERRIDE_GFX_VERSION`. Deploy a patched DaemonSet:

```bash
cat > ~/eai-build/k8s-device-plugin/k8s-ds-gfx1151.yaml << 'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: amdgpu-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: amdgpu-dp-ds
  template:
    metadata:
      labels:
        name: amdgpu-dp-ds
    spec:
      priorityClassName: system-node-critical
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      containers:
      - name: amdgpu-dp-cntr
        image: localhost:32000/amd-gpu-device-plugin:latest
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: [ALL]
        env:
        - name: HSA_OVERRIDE_GFX_VERSION
          value: "11.5.1"
        volumeMounts:
        - name: dp-dir
          mountPath: /var/lib/kubelet/device-plugins
        - name: sys-dir
          mountPath: /sys
        - name: dev-dir
          mountPath: /dev
      volumes:
      - name: dp-dir
        hostPath:
          path: /var/lib/kubelet/device-plugins
      - name: sys-dir
        hostPath:
          path: /sys
      - name: dev-dir
        hostPath:
          path: /dev
EOF

kubectl apply -f ~/eai-build/k8s-device-plugin/k8s-ds-gfx1151.yaml

# Verify GPU is exposed after ~30 seconds
kubectl get node -o custom-columns="NAME:.metadata.name,GPU:status.capacity.amd\.com/gpu"
# Expected: 1
```

### 3.3 — Apply Required Node Labels

> **Critical:** Kaiwo's Topology-Aware Scheduling requires these labels. Without them, all inference pods remain in `SchedulingGated` indefinitely.

```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

kubectl label node ${NODE} \
  kaiwo/worker=true \
  kaiwo/topology-block=block-a \
  kaiwo/topology-rack=rack-a \
  kaiwo/gpu-model=radeon-8060s \
  kaiwo/nodepool=amd-gfx1151-1gpu \
  amd.com/gpu.present=true \
  feature.node.kubernetes.io/hardware-vendor.amd=true

kubectl get node ${NODE} --show-labels | tr ',' '\n' | grep kaiwo
```

---

## Layer 4 — Platform Services (Helm)

These are upstream CNCF projects deployed via their official Helm charts — not built from source.

```bash
# cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 5m

# MetalLB
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb \
  --namespace metallb-system --create-namespace \
  --wait --timeout 5m

# Configure MetalLB IP pool
export MY_IP=$(hostname -I | awk '{print $1}')
kubectl apply -f - << EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
  - ${MY_IP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-advert
  namespace: metallb-system
EOF

# Longhorn (replicas=1 for single node)
helm repo add longhorn https://charts.longhorn.io
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --set defaultSettings.defaultReplicaCount=1 \
  --set defaultSettings.storageMinimalAvailablePercentage=10 \
  --wait --timeout 10m

# Set Longhorn as default StorageClass
kubectl patch storageclass longhorn \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Gateway API CRDs (required by AIM Engine routing)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

# Kueue
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.17.0/manifests.yaml
kubectl wait deploy/kueue-controller-manager -n kueue-system \
  --for=condition=available --timeout=5m

# KubeRay Operator
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm install kuberay-operator kuberay/kuberay-operator \
  --namespace ray-system --create-namespace \
  --wait --timeout 5m

# KServe
helm repo add kserve https://kserve.github.io/helm-charts/
helm install kserve kserve/kserve \
  --namespace kserve --create-namespace \
  --set kserve.controller.gateway.ingressGateway.className=kgateway \
  --wait --timeout 10m

# Verify all pods healthy
kubectl get pods -A | grep -v "Running\|Completed"
```

---

## Layer 5 — Orchestration: Build cluster-forge and kaiwo from Source

### 5.1 — Build cluster-forge

cluster-forge is a Go tool that bundles Helm charts and YAML into a deployable GitOps stack via ArgoCD + Gitea.

```bash
cd ~/eai-build
git clone https://github.com/silogen/cluster-forge.git
cd cluster-forge

# Enter the devbox development shell (manages exact Go + tool versions)
devbox shell

go version   # Should be go1.23.x as declared in devbox.json

# Build the binary
go build -o cf-bin .
./cf-bin --help   # Verify
```

Create a minimal config for single-node with AIRM + AI Workbench:

```bash
cp input/config.yaml input/config.yaml.default

cat > input/config.yaml << 'EOF'
clusterSize: small
components:
  - name: argocd
    enabled: true
  - name: gitea
    enabled: true
  - name: keycloak
    enabled: true
  - name: minio-operator
    enabled: true
  - name: minio-tenant
    enabled: true
  - name: cnpg-operator
    enabled: true
  - name: longhorn
    enabled: false
  - name: metallb
    enabled: false
  - name: cert-manager
    enabled: false
  - name: kueue
    enabled: false
  - name: kuberay-operator
    enabled: false
  - name: kaiwo
    enabled: true
  - name: amd-gpu-device-plugin
    enabled: false
EOF
```

Run the three build phases and deploy:

```bash
# Phase 1: Smelt — normalise inputs into working directory
LOG_LEVEL=info go run . smelt

# Phase 2 (optional): Review generated manifests
ls working/

# Phase 3: Cast — compile into deployable OCI image
LOG_LEVEL=info go run . cast

# Deploy — pass --disabled-apps=airm,airm-infra-keycloak to skip default AIRM
# (you will deploy AIRM manually in Layer 6 with the correct config)
export DOMAIN="${MY_IP}.nip.io"
./scripts/bootstrap.sh ${DOMAIN} --cluster-size=small --disabled-apps=airm,airm-infra-keycloak
```

Monitor ArgoCD:

```bash
kubectl get pods -n argocd
# Wait for argocd-server to be Running

# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Access UI (accept self-signed cert)
kubectl port-forward svc/argocd-server -n argocd 8443:443 &
# Open: https://localhost:8443
```

### 5.2 — Build and Deploy kaiwo from Source

kaiwo is a Go Kubernetes operator. Build it, push to your local registry, then deploy.

```bash
cd ~/eai-build
git clone https://github.com/silogen/kaiwo.git
cd kaiwo

# Build operator Docker image
make docker-build IMG=localhost:32000/kaiwo-operator:latest
docker push localhost:32000/kaiwo-operator:latest

# Install CRDs from source
make install

# Deploy operator
make deploy IMG=localhost:32000/kaiwo-operator:latest

# Verify
kubectl get pods -n kaiwo-system -l control-plane=kaiwo-controller-manager

# Build kaiwo CLI
go build -o ~/go/bin/kaiwo ./cmd/kaiwo/
kaiwo version
```

Configure resource flavors for your single GPU:

```bash
kubectl apply -f - << 'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: amd-gfx1151
spec:
  nodeLabels:
    kaiwo/gpu-model: radeon-8060s
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: cluster-queue
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: [amd.com/gpu, cpu, memory]
    flavors:
    - name: amd-gfx1151
      resources:
      - name: amd.com/gpu
        nominalQuota: 1
      - name: cpu
        nominalQuota: 11
      - name: memory
        nominalQuota: 100Gi
EOF
```

---

## Layer 6 — AI Services: AIM Engine (Source Build) + AIRM + Workbench

### 6.1 — Build AIM Engine from Source

AIM Engine is the Kubernetes operator that manages inference deployments via custom CRDs.

```bash
cd ~/eai-build
git clone https://github.com/amd-enterprise-ai/aim-engine.git
cd aim-engine

# Generate CRDs and Helm chart from source
make crds
make helm

# Inspect generated artefacts
ls dist/
# dist/crds.yaml — Custom Resource Definitions
# dist/chart/    — Helm chart

# Install CRDs
kubectl apply -f dist/crds.yaml
kubectl wait --for=condition=Established crd --all --timeout=60s

# Deploy operator
helm install aim-engine ./dist/chart \
  --namespace aim-system \
  --create-namespace \
  --set clusterRuntimeConfig.enable=true \
  --set clusterRuntimeConfig.spec.routing.enabled=true

kubectl get pods -n aim-system
# Expected: aim-engine-controller-manager-xxxxx Running
```

### 6.2 — Install AMD Resource Manager (AIRM) and AI Workbench

> AIRM and AI Workbench UI are deployed from AMD's pre-built OCI Helm charts — their application source is not public. All Kubernetes-layer components beneath them have been built from source above.

```bash
export DOMAIN="${MY_IP}.nip.io"
export HF_TOKEN="hf_xxxxxxxxxxxxxxxxxxxx"   # Your Hugging Face token

# AMD Resource Manager
helm install airm oci://docker.io/amdenterpriseai/charts/airm \
  --version 1.0.2 \
  --namespace airm \
  --create-namespace \
  --set global.domain=${DOMAIN} \
  --set global.certOption=generate \
  --set keycloak.enabled=false \
  --set keycloak.externalUrl="https://keycloak.${DOMAIN}" \
  --wait --timeout 15m

# AMD AI Workbench
helm install aiwb oci://docker.io/amdenterpriseai/charts/aiwb \
  --version 1.0.3 \
  --namespace aiwb \
  --create-namespace \
  --set global.domain=${DOMAIN} \
  --set global.deploymentMode=combined \
  --set global.huggingFaceToken=${HF_TOKEN} \
  --wait --timeout 15m
```

Retrieve credentials:

```bash
export DOMAIN="${MY_IP}.nip.io"

echo "=== AMD Resource Manager ==="
echo "URL: https://airmui.${DOMAIN}"
echo -n "Admin password: "
kubectl get secret airm-user-credentials -n airm \
  -o jsonpath='{.data.USER_PASSWORD}' | base64 -d && echo

echo ""
echo "=== AMD AI Workbench ==="
echo "URL: https://aiwbui.${DOMAIN}"
echo "Username: silogen-admin"
echo -n "Password: "
kubectl get secret keycloak-credentials -n keycloak \
  -o jsonpath='{.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}' | base64 -d && echo
```

> Open both URLs in your browser. Accept the self-signed certificate warning on first visit.

---

## Layer 7 — Inference: Gemma 4 26B-A4B on gfx1151

### ⚠️ Critical: Gemma 4 ROCm Bug on gfx1151

**The `gemma-4-26b-a4b-it` MoE model has a confirmed ROCm/HIP bug on gfx1151** causing an endless `<unused24><unused24>...` token loop when using the HIP backend. This is documented in llama.cpp issue #21416 by a Strix Halo 128 GB user with identical hardware.

**The Vulkan backend works correctly** with this model on gfx1151 and is the required backend. AMD confirmed Day 0 Gemma 4 support with explicit gfx1151 Vulkan builds.

### 7.1 — Build llama.cpp with Vulkan Backend

```bash
cd ~/eai-build
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp

cmake -S . -B build-vulkan \
  -DGGML_VULKAN=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON
cmake --build build-vulkan --config Release -j$(nproc)

# Verify Vulkan device is detected
./build-vulkan/bin/llama-cli --list-devices
# Should show: Vulkan0 AMD Radeon Graphics (gfx1151)
```

### 7.2 — Serve Gemma 4 26B-A4B

```bash
# Set your model path
MODEL_PATH="$HOME/models/gemma-4-26b-a4b-it-Q4_K_M.gguf"

# Verify model size
ls -lh ${MODEL_PATH}   # Should be ~14 GB

cd ~/eai-build/llama.cpp

./build-vulkan/bin/llama-server \
  --model ${MODEL_PATH} \
  --n-gpu-layers 999 \
  --ctx-size 32768 \
  --flash-attn \
  --host 0.0.0.0 \
  --port 8080 \
  --jinja \
  --cache-type-k q8_0 \
  --cache-type-v q8_0
```

> **Note:** `--jinja` is required for correct Gemma 4 chat template handling.

Verify:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4",
    "messages": [{"role": "user", "content": "Explain gfx1151 unified memory architecture briefly."}],
    "max_tokens": 300
  }'
```

### 7.3 — Register Endpoint in the AI Workbench

```bash
kubectl apply -f - << EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMModel
metadata:
  name: gemma-4-26b-a4b-local
  namespace: default
spec:
  displayName: "Gemma 4 26B-A4B (local Q4_K_M)"
  endpoint:
    url: "http://$(hostname -I | awk '{print $1}'):8080"
    type: OpenAI
  modelId: "gemma-4"
  capabilities:
    - chat
    - vision
EOF
```

The model will appear in the AI Workbench → **Models** → **My Models** and be available in the Chat UI.

---

## Final Verification Checklist

```bash
# 1. GPU visible to Kubernetes
kubectl get node -o custom-columns="NAME:.metadata.name,GPU:status.capacity.amd\.com/gpu"
# Expected: 1

# 2. All system pods healthy
kubectl get pods -A | grep -v "Running\|Completed" | grep -v "NAMESPACE"

# 3. AIM Engine operator running
kubectl get pods -n aim-system

# 4. Kaiwo operator running
kubectl get pods -n kaiwo-system

# 5. AIRM and Workbench running
kubectl get pods -n airm
kubectl get pods -n aiwb

# 6. Gemma 4 endpoint responding
curl -s http://localhost:8080/health && echo "Gemma 4 OK"

# 7. ArgoCD shows all apps Healthy
kubectl get applications -n argocd

# 8. AI Workbench UI accessible
echo "Open: https://aiwbui.$(hostname -I | awk '{print $1}').nip.io"
```

---

## Memory Allocation at Full Load

| Component | ~Memory |
|---|---|
| Ubuntu 24.04 OS | 4–6 GB |
| RKE2 / k3s + system pods | 4–6 GB |
| Kueue, KServe, KubeRay, cert-manager | 3–5 GB |
| ArgoCD, Gitea, Keycloak (via cluster-forge) | 4–6 GB |
| AIRM + AI Workbench pods | 4–6 GB |
| Gemma 4 26B-A4B Q4_K_M weights (GPU) | ~14 GB |
| KV cache (32K context @ Q8) | ~8 GB |
| **Available headroom** | **~73–87 GB** |

---

## Troubleshooting

| Issue | Symptom | Fix |
|---|---|---|
| Gemma 4 produces `<unused24>` loop | Endless repeated tokens | Use Vulkan backend, not HIP/ROCm |
| GPU shows 512 MB VRAM | `rocm-smi` shows tiny pool | Add `amdgpu.gttsize=131072` to GRUB params and reboot |
| Pod stuck in `SchedulingGated` | TAS topology error in workload events | Apply `kaiwo/worker` and `kaiwo/topology-block` labels (Layer 3.3) |
| AIM container OOM at startup | Container killed immediately | Use adapted Navi vLLM image as base; avoid ROCm 7.2 host + AIM container combination |
| Longhorn PVCs stuck in `Pending` | No default StorageClass | `kubectl patch storageclass longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'` |
| cluster-forge bootstrap fails at Gitea push | TLS certificate untrusted | Accept cert in browser at `https://gitea.<DOMAIN>` before re-running |
| AIM Engine CRD conflicts | `AlreadyExists` on apply | `kubectl delete crd --all --selector=app.kubernetes.io/managed-by=Helm` then re-apply |
| kaiwo operator `CrashLoopBackOff` | Missing AppWrapper CRD | `kubectl apply -f https://github.com/project-codeflare/appwrapper/releases/latest/download/install.yaml` |
| `vllm` fallback to CPU | `library=cpu` in logs | Ensure `HSA_OVERRIDE_GFX_VERSION=11.5.1` is set in `/etc/environment` and Docker env |
| `rocm-smi` not found after ROCm install | PATH missing | Add `/opt/rocm/bin` to PATH: `echo 'export PATH=$PATH:/opt/rocm/bin' >> ~/.bashrc` |
