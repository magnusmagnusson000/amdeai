"""Shared helpers for Telecom Assistant integration and E2E tests."""
from __future__ import annotations

import json
import os
import subprocess
import time
from contextlib import contextmanager
from typing import Iterator

import requests

NAMESPACE = os.environ.get("TELECOM_NAMESPACE", "telecom-assistant")
RELEASE = os.environ.get("TELECOM_RELEASE", "eai-telecom")
TIMEOUT = int(os.environ.get("TELECOM_TEST_TIMEOUT", "300"))


def kubectl_json(*args: str) -> dict:
    out = subprocess.check_output(["kubectl", *args], text=True)
    return json.loads(out) if out.strip() else {}


def pod_ready(prefix: str, namespace: str = NAMESPACE) -> bool:
    pods = kubectl_json("get", "pods", "-n", namespace, "-o", "json")["items"]
    for pod in pods:
        name = pod["metadata"]["name"]
        if not name.startswith(prefix):
            continue
        phase = pod["status"].get("phase")
        ready = all(
            c.get("ready") for c in pod["status"].get("containerStatuses") or []
        )
        if phase == "Running" and ready:
            return True
    return False


def wait_pod(prefix: str, timeout: int = TIMEOUT, namespace: str = NAMESPACE) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pod_ready(prefix, namespace):
            return
        time.sleep(5)
    pytest.fail(f"pod with prefix {prefix} not ready within {timeout}s")


def deployment_replicas(name: str, namespace: str = NAMESPACE) -> int:
    deploy = kubectl_json("get", "deploy", name, "-n", namespace, "-o", "json")
    return int(deploy.get("spec", {}).get("replicas", 0))


@contextmanager
def port_forward(
    svc: str,
    local_port: int,
    remote_port: int,
    namespace: str = NAMESPACE,
    wait_s: float = 2.0,
) -> Iterator[None]:
    proc = subprocess.Popen(
        [
            "kubectl",
            "port-forward",
            svc,
            f"{local_port}:{remote_port}",
            "-n",
            namespace,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(wait_s)
        yield
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def agent_env(name: str, namespace: str = NAMESPACE) -> str | None:
    deploy = kubectl_json(
        "get",
        "deploy",
        f"aimsb-telecom-assistant-{RELEASE}-agent",
        "-n",
        namespace,
        "-o",
        "json",
    )
    for env in deploy["spec"]["template"]["spec"]["containers"][0].get("env") or []:
        if env.get("name") == name:
            return env.get("value")
    return None


def qwen_llm_base_url() -> str:
    return os.environ.get(
        "QWEN_LLM_TEST_URL",
        "http://127.0.0.1:18080",
    )


def diffusiongemma_llm_base_url() -> str:
    return os.environ.get(
        "DG_LLM_TEST_URL",
        "http://127.0.0.1:18081",
    )


DG_LLM_MODEL = os.environ.get("DG_LLM_MODEL", "google/diffusiongemma-26B-A4B-it")
PHI4_LLM_MODEL = os.environ.get("PHI4_LLM_MODEL", "microsoft/phi-4")


def phi4_llm_base_url() -> str:
    return os.environ.get(
        "PHI4_LLM_TEST_URL",
        "http://127.0.0.1:18082",
    )


def check_phi4_llm_models(timeout: int = 30) -> None:
    r = requests.get(f"{phi4_llm_base_url()}/v1/models", timeout=timeout)
    assert r.status_code == 200
    data = r.json()
    ids = [m.get("id") for m in data.get("data", [])]
    assert any(
        "phi" in (mid or "").lower() or mid == PHI4_LLM_MODEL for mid in ids
    )


def check_qwen_llm_models(timeout: int = 30) -> None:
    r = requests.get(f"{qwen_llm_base_url()}/v1/models", timeout=timeout)
    assert r.status_code == 200
    data = r.json()
    ids = [m.get("id") for m in data.get("data", [])]
    assert any("Qwen" in (mid or "") for mid in ids)


def check_diffusiongemma_llm_models(timeout: int = 30) -> None:
    r = requests.get(f"{diffusiongemma_llm_base_url()}/v1/models", timeout=timeout)
    assert r.status_code == 200
    data = r.json()
    ids = [m.get("id") for m in data.get("data", [])]
    assert any(
        "diffusiongemma" in (mid or "").lower() or mid == DG_LLM_MODEL for mid in ids
    )
