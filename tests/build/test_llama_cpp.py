"""Build verification for ggml-org/llama.cpp (Vulkan)."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
import requests

@pytest.fixture
def llama_bin(eai_build: Path) -> Path:
    return eai_build / "llama.cpp" / "build-vulkan" / "bin"


def test_server_binary_exists(eai_build: Path, llama_bin: Path):
    if not (eai_build / "llama.cpp").is_dir():
        pytest.skip("llama.cpp not cloned")
    server = llama_bin / "llama-server"
    assert server.is_file() and server.stat().st_mode & 0o111


def test_cli_binary_exists(eai_build: Path, llama_bin: Path):
    if not (eai_build / "llama.cpp").is_dir():
        pytest.skip("llama.cpp not cloned")
    cli = llama_bin / "llama-cli"
    assert cli.is_file()


def test_vulkan_device_detected(llama_bin: Path):
    cli = llama_bin / "llama-cli"
    if not cli.is_file():
        pytest.skip("llama-cli not built")
    r = subprocess.run([str(cli), "--list-devices"], capture_output=True, text=True, timeout=60)
    out = (r.stdout + r.stderr).lower()
    assert "vulkan" in out


def test_server_health():
    try:
        r = requests.get("http://localhost:8080/health", timeout=5)
    except requests.RequestException:
        pytest.skip("llama-server not running")
    assert r.status_code == 200


def test_inference_smoke():
    try:
        r = requests.post(
            "http://localhost:8080/v1/chat/completions",
            json={
                "model": "gemma-4",
                "messages": [{"role": "user", "content": "Hi"}],
                "max_tokens": 10,
            },
            timeout=120,
        )
    except requests.RequestException:
        pytest.skip("llama-server not running")
    assert r.status_code == 200
    data = r.json()
    content = data["choices"][0]["message"]["content"]
    assert content and "<unused24>" not in content
