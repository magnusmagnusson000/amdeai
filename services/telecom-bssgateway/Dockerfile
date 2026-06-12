# Reuses telecom-stt-service base (python:3.11-slim already in containerd)
# to avoid Docker Hub pulls when building BSSGateway locally.
FROM telecom-stt-service:local
WORKDIR /app
COPY main.py .
EXPOSE 8001
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
