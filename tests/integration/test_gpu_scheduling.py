"""Integration: GPU labels and schedulable pod."""
from __future__ import annotations

import json
import subprocess
import time

import pytest

REQUIRED_LABELS = [
    "kaiwo/worker",
    "kaiwo/topology-block",
    "kaiwo/topology-rack",
    "kaiwo/gpu-model",
    "kaiwo/nodepool",
    "amd.com/gpu.present",
]


def test_node_labels(skip_without_k8s):
    node = subprocess.check_output(
        ["kubectl", "get", "nodes", "-o", "jsonpath={.items[0].metadata.name}"],
        text=True,
    ).strip()
    raw = subprocess.check_output(["kubectl", "get", "node", node, "-o", "json"], text=True)
    labels = json.loads(raw)["metadata"]["labels"]
    for key in REQUIRED_LABELS:
        assert key in labels and labels[key], f"missing label {key}"


def test_gpu_pod_schedulable(skip_without_k8s):
    manifest = """
apiVersion: v1
kind: Pod
metadata:
  name: eai-gpu-smoke
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
    resources:
      limits:
        amd.com/gpu: "1"
"""
    subprocess.run(["kubectl", "delete", "pod", "eai-gpu-smoke", "--ignore-not-found"], check=False)
    subprocess.run(["kubectl", "apply", "-f", "-"], input=manifest, text=True, check=True)
    try:
        for _ in range(60):
            phase = subprocess.check_output(
                [
                    "kubectl",
                    "get",
                    "pod",
                    "eai-gpu-smoke",
                    "-o",
                    "jsonpath={.status.phase}",
                ],
                text=True,
            ).strip()
            if phase == "Running":
                return
            if phase in ("Failed", "Succeeded"):
                break
            time.sleep(2)
        pytest.fail("GPU smoke pod did not reach Running")
    finally:
        subprocess.run(["kubectl", "delete", "pod", "eai-gpu-smoke", "--ignore-not-found"], check=False)
