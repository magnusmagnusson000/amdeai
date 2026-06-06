#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
check_disk_before_step "fetch-study-sources"

ROOT="${EAI_BUILD_DIR:-$HOME/eai-build}"
CHARTS_DIR="$ROOT/vendor-charts"
ROCM_DIR="$ROOT/rocm"
mkdir -p "$ROOT" "$CHARTS_DIR" "$ROCM_DIR"

clone_depth1() {
  local url="$1"
  local dir="$2"
  if [[ -d "$dir/.git" ]]; then
    echo "[sync] $(basename "$dir")"
    git -C "$dir" fetch --depth 1 origin
    git -C "$dir" reset --hard origin/HEAD
    git -C "$dir" clean -fdx
  else
    echo "[clone] $url -> $dir"
    git clone --depth 1 "$url" "$dir"
  fi
}

pull_oci_chart() {
  local ref="$1"
  local version="$2"
  local out_dir="$3"
  rm -rf "$out_dir"
  mkdir -p "$(dirname "$out_dir")"
  echo "[chart] $ref:$version -> $out_dir"
  helm pull "$ref" --version "$version" --untar --untardir "$(dirname "$out_dir")"
  local pulled_dir
  pulled_dir="$(dirname "$out_dir")/$(basename "$ref")"
  if [[ "$pulled_dir" != "$out_dir" && -d "$pulled_dir" ]]; then
    mv "$pulled_dir" "$out_dir"
  fi
}

create_private_stub() {
  local out_dir="$1"
  local title="$2"
  local ref="$3"
  local version="$4"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  cat > "$out_dir/README.md" <<EOF
# $title

This component is part of the local EAI study tree, but the upstream source or chart could not be fetched anonymously from this machine.

- Reference: \`$ref\`
- Version: \`$version\`
- Status: access restricted / authentication required

For public-study alternatives, use the surrounding stack repos in \`~/eai-build\`:

- \`aim-engine\`
- \`cluster-forge\`
- \`kaiwo\`
- \`kserve\`
- \`kuberay\`
- \`kueue\`

EOF
}

echo "== Public source repos =="
clone_depth1 https://github.com/ROCm/ROCm.git "$ROCM_DIR/ROCm"
clone_depth1 https://github.com/ROCm/HIP.git "$ROCM_DIR/HIP"
clone_depth1 https://github.com/ROCm/ROCR-Runtime.git "$ROCM_DIR/ROCR-Runtime"
clone_depth1 https://github.com/ROCm/rocm-systems.git "$ROCM_DIR/rocm-systems"
clone_depth1 https://github.com/ROCm/ROCm-Device-Libs.git "$ROCM_DIR/ROCm-Device-Libs"
clone_depth1 https://github.com/ROCm/clr.git "$ROCM_DIR/clr"
clone_depth1 https://github.com/ROCm/llvm-project.git "$ROCM_DIR/llvm-project"
clone_depth1 https://github.com/ROCm/rocminfo.git "$ROCM_DIR/rocminfo"
clone_depth1 https://github.com/ROCm/rocm_smi_lib.git "$ROCM_DIR/rocm_smi_lib"

clone_depth1 https://github.com/k3s-io/k3s.git "$ROOT/k3s"
clone_depth1 https://github.com/ROCm/k8s-device-plugin.git "$ROOT/k8s-device-plugin"
clone_depth1 https://github.com/cert-manager/cert-manager.git "$ROOT/cert-manager"
clone_depth1 https://github.com/metallb/metallb.git "$ROOT/metallb"
clone_depth1 https://github.com/longhorn/longhorn.git "$ROOT/longhorn"
clone_depth1 https://github.com/kubernetes-sigs/gateway-api.git "$ROOT/gateway-api"
clone_depth1 https://github.com/kubernetes-sigs/kueue.git "$ROOT/kueue"
clone_depth1 https://github.com/ray-project/kuberay.git "$ROOT/kuberay"
clone_depth1 https://github.com/kserve/kserve.git "$ROOT/kserve"
clone_depth1 https://github.com/silogen/cluster-forge.git "$ROOT/cluster-forge"
clone_depth1 https://github.com/silogen/kaiwo.git "$ROOT/kaiwo"
clone_depth1 https://github.com/amd-enterprise-ai/aim-engine.git "$ROOT/aim-engine"
clone_depth1 https://github.com/ggml-org/llama.cpp.git "$ROOT/llama.cpp"

echo "== OCI chart extracts (source not public) =="
if ! pull_oci_chart oci://docker.io/amdenterpriseai/charts/airm 1.0.2 "$CHARTS_DIR/airm"; then
  create_private_stub "$CHARTS_DIR/airm" "AMD Resource Manager (AIRM)" "oci://docker.io/amdenterpriseai/charts/airm" "1.0.2"
fi
if ! pull_oci_chart oci://docker.io/amdenterpriseai/charts/aiwb 1.0.3 "$CHARTS_DIR/aiwb"; then
  create_private_stub "$CHARTS_DIR/aiwb" "AMD AI Workbench (AIWB)" "oci://docker.io/amdenterpriseai/charts/aiwb" "1.0.3"
fi

echo "== Inventory =="
python3 - <<'PY'
from pathlib import Path

root = Path.home() / "eai-build"
lines = [
    "# EAI Build Study Index",
    "",
    "This tree contains local source snapshots for the public parts of the stack, plus extracted OCI charts for AMD components whose application source is not public.",
    "",
    "| Component | Local path | Type | Notes |",
    "|---|---|---|---|",
    f"| ROCm umbrella | `{root / 'rocm/ROCm'}` | git repo | AMD ROCm umbrella repo |",
    f"| HIP | `{root / 'rocm/HIP'}` | git repo | HIP runtime/compiler-facing API |",
    f"| ROCR-Runtime | `{root / 'rocm/ROCR-Runtime'}` | git repo | Deprecated HSA runtime repo, useful for historical/runtime tracing |",
    f"| rocm-systems | `{root / 'rocm/rocm-systems'}` | git repo | Current home for ROCm runtime/system components |",
    f"| ROCm-Device-Libs | `{root / 'rocm/ROCm-Device-Libs'}` | git repo | GPU device bitcode libraries used by ROCm toolchain |",
    f"| clr | `{root / 'rocm/clr'}` | git repo | ROCclr + HIP/OpenCL runtime implementation |",
    f"| llvm-project | `{root / 'rocm/llvm-project'}` | git repo | AMD-maintained LLVM fork for ROCm compiler toolchain |",
    f"| rocminfo | `{root / 'rocm/rocminfo'}` | git repo | HSA agent inspection tool |",
    f"| rocm_smi_lib | `{root / 'rocm/rocm_smi_lib'}` | git repo | ROCm SMI library/tooling |",
    f"| k3s | `{root / 'k3s'}` | git repo | Kubernetes distribution source |",
    f"| k8s-device-plugin | `{root / 'k8s-device-plugin'}` | git repo | AMD GPU device plugin |",
    f"| cert-manager | `{root / 'cert-manager'}` | git repo | TLS operator |",
    f"| metallb | `{root / 'metallb'}` | git repo | Bare-metal load balancer |",
    f"| longhorn | `{root / 'longhorn'}` | git repo | Storage platform |",
    f"| gateway-api | `{root / 'gateway-api'}` | git repo | Gateway CRDs/specs |",
    f"| kueue | `{root / 'kueue'}` | git repo | Queueing/scheduling |",
    f"| kuberay | `{root / 'kuberay'}` | git repo | Ray operator |",
    f"| kserve | `{root / 'kserve'}` | git repo | Serving platform |",
    f"| cluster-forge | `{root / 'cluster-forge'}` | git repo | GitOps platform bootstrap |",
    f"| kaiwo | `{root / 'kaiwo'}` | git repo | AI workload orchestration |",
    f"| aim-engine | `{root / 'aim-engine'}` | git repo | AIM operator |",
    f"| llama.cpp | `{root / 'llama.cpp'}` | git repo | Local Vulkan inference |",
    f"| AIRM chart | `{root / 'vendor-charts/airm'}` | extracted OCI chart | Helm chart only; app source not public |",
    f"| AIWB chart | `{root / 'vendor-charts/aiwb'}` | extracted OCI chart | Helm chart only; app source not public |",
]
(root / "STACK_INDEX.md").write_text("\n".join(lines) + "\n")
print(root / "STACK_INDEX.md")
PY

disk_report "fetch-study-sources-done"
echo "Study source tree ready under $ROOT"
