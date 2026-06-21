# Custom AIM image for DiffusionGemma on gfx1151 (Strix Halo / Radeon 8060S / R9700)
#
# Model: google/diffusiongemma-26B-A4B-it (26B total / 4B active MoE, discrete diffusion LLM)
#
# STRATEGY: same as aim-gfx1151-qwen3-6-35b-moe — aim-runtime + entrypoint.py from aim-base:0.11
# layered onto kyuz0/vllm-therock-gfx1151:latest (vLLM 0.22+ with DiffusionGemma).
# Use :stable for autoregressive models only; DiffusionGemma needs --diffusion-config.

FROM amdenterpriseai/aim-base:0.11 AS aim-src

# Pin dated TheRock build (ROCm userspace + vLLM); :latest lagged during gfx1151 bring-up.
FROM kyuz0/vllm-therock-gfx1151:20260617-094558

COPY --from=aim-src /workspace/aim-runtime /workspace/aim-runtime
COPY --from=aim-src /workspace/entrypoint.py /workspace/entrypoint.py
COPY profiles/google/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency.yaml \
  /workspace/aim-runtime/profiles/google/diffusiongemma-26b/diffusiongemma-26b-r9700-gfx1151-latency.yaml

RUN pip install --no-cache-dir "huggingface-hub>=1.5.0,<2.0"

ENV PYTHONPATH="/workspace/aim-runtime/src"
ENV AIM_CONFIG_PATH="/workspace/aim-runtime/config"
ENV AIM_ALLOW_GENERAL_PROFILE_FALLBACK="true"
ENV AIM_ACCELERATOR_FAMILY="instinct"
ENV AIM_ACCELERATOR_TYPE="gpu"
ENV AIM_UPSTREAM_IMAGE_REF="docker.io/kyuz0/vllm-therock-gfx1151:20260617-094558"
ENV AIM_ID="google/diffusiongemma-26b"

LABEL com.amd.aim.model.canonicalName="google/diffusiongemma-26b-a4b-it"
LABEL com.amd.aim.base.version="0.11"
LABEL com.amd.aim.gfx="gfx1151"

WORKDIR /workspace

ENTRYPOINT ["./entrypoint.py"]
