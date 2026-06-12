# Custom AIM image for gfx1151 (Strix Halo / Radeon 8060S / R9700)
#
# WHY THIS EXISTS:
#   amdenterpriseai/aim-base:0.11 bundles PyTorch compiled for CDNA (MI300X).
#   On gfx1151 (RDNA 3.5) that PyTorch segfaults.
#
#   kyuz0/vllm-therock-gfx1151:stable provides vLLM 0.19.2rc1 with PyTorch
#   compiled for gfx1151 via AMD TheRock nightlies — this image CAN run
#   inference on gfx1151.
#
# STRATEGY:
#   aim-runtime (/workspace/aim-runtime/src/) is pure Python. No GPU deps.
#   It reads a profile YAML (injected by the AIM operator via ConfigMap) and
#   os.execv()s into vLLM. We copy it verbatim from aim-base and run it on
#   the gfx1151-capable vLLM stack.
#
# RESULT:
#   AIMService → InferenceService → this image → aim-runtime → vLLM 0.19.2rc1
#   Full managed AIM flow on gfx1151, no separate Deployment needed.
#
# Build:
#   IMAGE=192.168.32.13:32000/aim-gfx1151-qwen3-6-27b:0.11-therock
#   docker build -t "$IMAGE" images/aim-gfx1151-qwen3-6-27b/
#   docker push "$IMAGE"

# Stage 1: extract aim-runtime (pure Python, no GPU deps) from official image
FROM amdenterpriseai/aim-base:0.11 AS aim-src

# Stage 2: gfx1151-capable inference stack with vLLM 0.19.2rc1
FROM kyuz0/vllm-therock-gfx1151:stable

# Copy the aim-runtime Python package — source only, no GPU dependencies
COPY --from=aim-src /workspace/aim-runtime /workspace/aim-runtime

# Install aim-runtime's Python requirements on top of the vLLM environment.
# These are lightweight (pyyaml, pydantic, hf-hub, etc.) and do not touch ROCm.
RUN pip install --no-cache-dir -r /workspace/aim-runtime/requirements.txt

# Replicate aim-base environment so aim-runtime finds its config and src package
ENV PYTHONPATH="/workspace/aim-runtime/src"
ENV AIM_CONFIG_PATH="/workspace/aim-runtime/config"
ENV AIM_ALLOW_GENERAL_PROFILE_FALLBACK="true"
ENV AIM_ACCELERATOR_FAMILY="instinct"
ENV AIM_ACCELERATOR_TYPE="gpu"
ENV AIM_UPSTREAM_IMAGE_REF="docker.io/kyuz0/vllm-therock-gfx1151:stable"

# OCI label for AIM operator discovery (mirrors what official aim images set)
LABEL com.amd.aim.model.canonicalName="qwen/qwen3-6-27b"
LABEL com.amd.aim.base.version="0.11"
LABEL com.amd.aim.gfx="gfx1151"

WORKDIR /workspace

# aim-runtime has no installed binary — invoked as a Python module.
# The operator mounts the profile ConfigMap at:
#   /workspace/aim-runtime/profiles/custom/qwen/qwen3-6-27b/
# and injects AIM_PROFILE_ID=custom/qwen/qwen3-6-27b/vllm-r9700-bf16-tp1-latency
# aim-runtime reads that YAML, sets env vars, and execv()s into vLLM.
ENTRYPOINT ["python", "-m", "aim_runtime", "serve"]
