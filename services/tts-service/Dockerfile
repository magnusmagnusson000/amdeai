FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsndfile1 curl ffmpeg espeak-ng \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
# Torch CPU then Kokoro stack (large; build needs stable network)
RUN pip install --no-cache-dir --timeout 300 \
    torch --index-url https://download.pytorch.org/whl/cpu \
    && pip install --no-cache-dir --timeout 300 -r requirements.txt
COPY . .
EXPOSE 8002
ENV HF_HOME=/app/hf_cache
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8002", "--workers", "1"]
