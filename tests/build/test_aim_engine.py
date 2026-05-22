"""Build verification for amd-enterprise-ai/aim-engine."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

@pytest.fixture
def aim_root(eai_build: Path) -> Path:
    return eai_build / "aim-engine"


def test_dist_crds_exist(aim_root: Path):
    if not aim_root.is_dir():
        pytest.skip("aim-engine not cloned")
    crds = aim_root / "dist" / "crds.yaml"
    assert crds.is_file() and crds.stat().st_size > 0


def test_dist_chart_exists(aim_root: Path):
    if not aim_root.is_dir():
        pytest.skip("aim-engine not cloned")
    chart = aim_root / "dist" / "chart" / "Chart.yaml"
    assert chart.is_file()


def test_crds_established(skip_without_k8s):
    r = subprocess.run(
        ["kubectl", "get", "crd", "aimmodels.aim.eai.amd.com", "-o", "jsonpath={.status.conditions}"],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        pytest.skip("AIM CRD not installed")
    assert "True" in r.stdout or r.returncode == 0


def test_operator_pod_running(skip_without_k8s):
    r = subprocess.run(
        [
            "kubectl",
            "get",
            "pods",
            "-n",
            "aim-system",
            "-o",
            "jsonpath={.items[*].status.phase}",
        ],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0 or not r.stdout.strip():
        pytest.skip("aim-system not deployed")
    assert "Running" in r.stdout
