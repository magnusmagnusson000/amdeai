"""Shared pytest fixtures for EAI suite validation."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

EAI_BUILD = Path(os.environ.get("EAI_BUILD_DIR", Path.home() / "eai-build"))


@pytest.fixture(scope="session")
def eai_build() -> Path:
    return EAI_BUILD


@pytest.fixture(scope="session")
def my_ip() -> str:
    out = subprocess.check_output(["hostname", "-I"], text=True)
    return out.split()[0]


@pytest.fixture(scope="session")
def domain(my_ip: str) -> str:
    return f"{my_ip}.nip.io"


@pytest.fixture(scope="session")
def k8s_available() -> bool:
    try:
        subprocess.run(
            ["kubectl", "cluster-info"],
            capture_output=True,
            check=True,
            timeout=15,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return False


@pytest.fixture
def skip_without_k8s(k8s_available: bool):
    if not k8s_available:
        pytest.skip("Kubernetes cluster not available")
