"""Build verification for ROCm/k8s-device-plugin."""
from __future__ import annotations

import subprocess

import pytest


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


@pytest.mark.skipif(
    not __import__("shutil").which("docker"),
    reason="docker not installed",
)
def test_image_exists():
    r = _run(["docker", "image", "inspect", "localhost:32000/amd-gpu-device-plugin:latest"])
    assert r.returncode == 0, r.stderr


def test_daemonset_running(skip_without_k8s):
    r = _run(
        [
            "kubectl",
            "get",
            "ds",
            "amdgpu-device-plugin-daemonset",
            "-n",
            "kube-system",
            "--no-headers",
        ]
    )
    assert r.returncode == 0, r.stderr
    parts = r.stdout.split()
    assert len(parts) >= 4
    ready = int(parts[3].split("/")[0])
    assert ready >= 1


def test_gpu_resource_advertised(skip_without_k8s):
    r = _run(
        [
            "kubectl",
            "get",
            "nodes",
            "-o",
            "jsonpath={.items[0].status.capacity.amd\\.com/gpu}",
        ]
    )
    assert r.stdout.strip() == "1"
