"""Integration tests for Telecom Assistant blueprint on gfx1151 EAI cluster."""
from __future__ import annotations

import json
import os
import subprocess
import time

import pytest
import requests

NAMESPACE = os.environ.get("TELECOM_NAMESPACE", "telecom-assistant")
RELEASE = os.environ.get("TELECOM_RELEASE", "eai-telecom")
GEMMA_NS = os.environ.get("GEMMA_NAMESPACE", "demo")
TIMEOUT = int(os.environ.get("TELECOM_TEST_TIMEOUT", "300"))


def _kubectl_json(*args: str) -> dict:
    out = subprocess.check_output(["kubectl", *args], text=True)
    return json.loads(out) if out.strip() else {}


def _pod_ready(prefix: str) -> bool:
    pods = _kubectl_json("get", "pods", "-n", NAMESPACE, "-o", "json")["items"]
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


def _wait_pod(prefix: str, timeout: int = TIMEOUT) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _pod_ready(prefix):
            return
        time.sleep(5)
    pytest.fail(f"pod with prefix {prefix} not ready within {timeout}s")


@pytest.fixture
def skip_without_telecom(skip_without_k8s):
    try:
        subprocess.check_output(
            ["kubectl", "get", "namespace", NAMESPACE],
            stderr=subprocess.STDOUT,
            text=True,
        )
    except subprocess.CalledProcessError:
        pytest.skip(f"namespace {NAMESPACE} not found — run scripts/09-telecom-assistant.sh")


def test_namespace_exists(skip_without_telecom):
    ns = _kubectl_json("get", "namespace", NAMESPACE, "-o", "json")
    assert ns["metadata"]["name"] == NAMESPACE


def test_livekit_running(skip_without_telecom):
    _wait_pod(f"{RELEASE}-livekit", timeout=120)
    assert _pod_ready(f"{RELEASE}-livekit")


def test_postgres_redis_running(skip_without_telecom):
    _wait_pod("aimsb-telecom-assistant-", timeout=180)
    assert _pod_ready("aimsb-telecom-assistant-eai-telecom-postgres")
    assert _pod_ready("aimsb-telecom-assistant-eai-telecom-redis")


def test_bssgateway_health(skip_without_telecom):
    _wait_pod("aimsb-telecom-assistant-eai-telecom-bssgateway", timeout=180)

    def pf_and_check() -> None:
        proc = subprocess.Popen(
            [
                "kubectl",
                "port-forward",
                f"svc/aimsb-telecom-assistant-{RELEASE}-bssgateway",
                "18001:8001",
                "-n",
                NAMESPACE,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            time.sleep(2)
            r = requests.get("http://127.0.0.1:18001/health", timeout=10)
            assert r.status_code == 200
            assert r.json().get("status") == "ok"
            user = requests.get(
                "http://127.0.0.1:18001/users/user/milkyway", timeout=10
            )
            assert user.status_code == 200
            body = user.json()
            assert body["first_name"] == "John"
            assert body["last_name"] == "Black"
        finally:
            proc.terminate()
            proc.wait(timeout=10)

    pf_and_check()


def test_chromadb_heartbeat(skip_without_telecom):
    _wait_pod(f"{RELEASE}-chromadb", timeout=240)

    proc = subprocess.Popen(
        [
            "kubectl",
            "port-forward",
            f"svc/{RELEASE}-chromadb",
            "18000:8000",
            "-n",
            NAMESPACE,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(2)
        r = requests.get("http://127.0.0.1:18000/api/v2/heartbeat", timeout=15)
        assert r.status_code == 200
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def test_embedding_models(skip_without_telecom):
    _wait_pod(f"{RELEASE}-embedding", timeout=360)

    proc = subprocess.Popen(
        [
            "kubectl",
            "port-forward",
            f"svc/{RELEASE}-embedding",
            "17997:7997",
            "-n",
            NAMESPACE,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(2)
        r = requests.get("http://127.0.0.1:17997/models", timeout=30)
        assert r.status_code == 200
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def test_gemma_llm_bridge(skip_without_telecom):
    """LLM for telecom is host Gemma (also reachable via demo namespace Service)."""
    base = os.environ.get("GEMMA_TEST_URL", "http://127.0.0.1:8081")
    r = requests.get(f"{base}/health", timeout=10)
    assert r.status_code == 200
    models = requests.get(f"{base}/v1/models", timeout=10)
    assert models.status_code == 200
    chat = requests.post(
        f"{base}/v1/chat/completions",
        json={
            "model": "gemma-4-31b",
            "messages": [{"role": "user", "content": "Say hi in one word."}],
            "max_tokens": 8,
        },
        timeout=120,
    )
    assert chat.status_code == 200
    assert "choices" in chat.json()


def test_frontend_connection_api(skip_without_telecom):
    _wait_pod("aimsb-telecom-assistant-eai-telecom-frontend", timeout=240)

    proc = subprocess.Popen(
        [
            "kubectl",
            "port-forward",
            f"svc/aimsb-telecom-assistant-{RELEASE}-frontend",
            "13000:3000",
            "-n",
            NAMESPACE,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(2)
        r = requests.post(
            "http://127.0.0.1:13000/api/connection-details",
            json={},
            timeout=15,
        )
        assert r.status_code == 200
        data = r.json()
        assert data.get("serverUrl")
        assert data.get("participantToken")
        assert data.get("roomName")
    finally:
        proc.terminate()
        proc.wait(timeout=10)


@pytest.mark.skipif(
    not os.environ.get("TELECOM_TEST_AGENT", ""),
    reason="Set TELECOM_TEST_AGENT=1 when agent pod is Ready",
)
def test_agent_running(skip_without_telecom):
    _wait_pod("aimsb-telecom-assistant-eai-telecom-agent", timeout=600)
    assert _pod_ready("aimsb-telecom-assistant-eai-telecom-agent")
