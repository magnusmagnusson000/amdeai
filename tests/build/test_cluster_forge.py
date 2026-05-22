"""Build verification for silogen/cluster-forge."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


@pytest.fixture
def cf_root(eai_build: Path) -> Path:
    return eai_build / "cluster-forge"


def test_bootstrap_script_exists(cf_root: Path):
    if not cf_root.is_dir():
        pytest.skip("cluster-forge not cloned")
    bootstrap = cf_root / "scripts" / "bootstrap.sh"
    assert bootstrap.is_file()


def test_sources_populated(cf_root: Path):
    if not cf_root.is_dir():
        pytest.skip("cluster-forge not cloned")
    sources = cf_root / "sources"
    assert sources.is_dir()
    assert len(list(sources.iterdir())) >= 5


def test_argocd_namespace_or_apps(skip_without_k8s):
    r = subprocess.run(
        ["kubectl", "get", "ns", "argocd"],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        pytest.skip("ArgoCD not deployed yet (bootstrap incomplete)")
    assert "argocd" in r.stdout
