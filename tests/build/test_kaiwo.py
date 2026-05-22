"""Build verification for silogen/kaiwo."""
from __future__ import annotations

import shutil
import subprocess

import pytest


def test_operator_image_pushed():
    if not shutil.which("docker"):
        pytest.skip("docker not installed")
    r = subprocess.run(
        ["docker", "image", "inspect", "localhost:32000/kaiwo-operator:latest"],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0


def test_cli_version():
    kaiwo = shutil.which("kaiwo") or str(__import__("pathlib").Path.home() / "go/bin/kaiwo")
    if not __import__("pathlib").Path(kaiwo).is_file():
        pytest.skip("kaiwo CLI not built")
    r = subprocess.run([kaiwo, "version"], capture_output=True, text=True)
    assert r.returncode == 0
    assert r.stdout.strip()


def test_crds_installed(skip_without_k8s):
    r = subprocess.run(["kubectl", "get", "crd", "-o", "name"], capture_output=True, text=True)
    assert r.returncode == 0
    # CRD name may vary by version; accept kaiwo in output
    assert "kaiwo" in r.stdout.lower()
