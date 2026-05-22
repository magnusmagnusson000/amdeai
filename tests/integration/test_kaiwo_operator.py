"""Integration: Kaiwo operator and Kueue resources."""
from __future__ import annotations

import subprocess

import pytest


def test_operator_ready(skip_without_k8s):
    r = subprocess.run(
        [
            "kubectl",
            "get",
            "deploy",
            "-n",
            "kaiwo-system",
            "-o",
            "jsonpath={.items[0].status.availableReplicas}",
        ],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        pytest.skip("kaiwo-system not found")
    assert int(r.stdout or "0") >= 1


def test_resource_flavor_exists(skip_without_k8s):
    r = subprocess.run(
        ["kubectl", "get", "resourceflavor", "amd-gfx1151"],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0


def test_cluster_queue_exists(skip_without_k8s):
    r = subprocess.run(
        ["kubectl", "get", "clusterqueue", "cluster-queue"],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0
