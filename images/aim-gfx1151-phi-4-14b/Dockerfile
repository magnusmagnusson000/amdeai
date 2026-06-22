# Custom AIM image for Phi-4 14B on gfx1151 (Strix Halo / R9700)
#
# Layers aim-runtime from aim-base:0.11 onto kyuz0/vllm-therock-gfx1151:stable.
# See images/aim-gfx1151-qwen3-6-27b/Dockerfile for rationale.
#
# Build:
#   IMAGE=$(hostname -s):32000/aim-gfx1151-phi-4-14b:0.11-therock
#   docker build -t "$IMAGE" images/aim-gfx1151-phi-4-14b/
#   docker push "$IMAGE"

FROM amdenterpriseai/aim-base:0.11 AS aim-src

FROM kyuz0/vllm-therock-gfx1151:stable

COPY --from=aim-src /workspace/aim-runtime /workspace/aim-runtime

RUN pip install --no-cache-dir "huggingface-hub>=1.5.0,<2.0"

ENV PYTHONPATH="/workspace/aim-runtime/src"
ENV AIM_CONFIG_PATH="/workspace/aim-runtime/config"
ENV AIM_ALLOW_GENERAL_PROFILE_FALLBACK="true"
ENV AIM_ACCELERATOR_FAMILY="instinct"
ENV AIM_ACCELERATOR_TYPE="gpu"
ENV AIM_UPSTREAM_IMAGE_REF="docker.io/kyuz0/vllm-therock-gfx1151:stable"

RUN cat > /workspace/aim-runtime/src/aim_runtime/__main__.py <<'PYEOF'
from aim_runtime import AIMRuntime
from aim_runtime.config import AIMConfig
AIMRuntime(AIMConfig.from_environment()).serve()
PYEOF

LABEL com.amd.aim.model.canonicalName="microsoft/phi-4"
LABEL com.amd.aim.base.version="0.11"
LABEL com.amd.aim.gfx="gfx1151"

WORKDIR /workspace
ENTRYPOINT ["python", "-m", "aim_runtime"]
