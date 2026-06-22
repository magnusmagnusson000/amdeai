"""Integration tests for Phi-4 14B AIM on gfx1151."""
from __future__ import annotations

import os
import subprocess

import pytest

pytestmark = pytest.mark.usefixtures("skip_without_k8s")

PROFILE_TEMPLATE = "phi-4-14b-r9700-gfx1151-latency"
MODEL_NAME = "microsoft-phi-4-14b"
LLM_MODEL = os.environ.get("PHI4_LLM_MODEL", "microsoft/phi-4")


def _kubectl(args: list[str], timeout: int = 30) -> str:
    return subprocess.check_output(
        ["kubectl"] + args, stderr=subprocess.STDOUT, text=True, timeout=timeout
    ).strip()


def test_phi4_catalog_template_ready():
    status = _kubectl(
        ["get", "aimclusterservicetemplate", PROFILE_TEMPLATE, "-o", "jsonpath={.status.status}"]
    )
    assert status == "Ready", (
        f"Template status={status!r} — run: CATALOG_ONLY=1 bash scripts/13-phi-4-14b.sh"
    )
    matching = _kubectl(
        ["get", "aimclusterprofile", PROFILE_TEMPLATE, "-o", "jsonpath={.status.matchingNodes}"]
    )
    assert matching and int(matching) >= 1


def test_phi4_aimservice_running():
    if not os.environ.get("PHI4_AIM_DEPLOYED", ""):
        pytest.skip("Set PHI4_AIM_DEPLOYED=1 after deploy")
    out = _kubectl(["get", "aimservice", "-n", "demo", "-o", "jsonpath={.items[*].status.status}"])
    assert "Running" in out


def test_phi4_predictor_health():
    if not os.environ.get("PHI4_AIM_DEPLOYED", ""):
        pytest.skip("Set PHI4_AIM_DEPLOYED=1 after deploy")
    out = subprocess.check_output(
        [
            "kubectl", "run", "phi4-models-test", "--rm", "-i", "--restart=Never",
            "--image=curlimages/curl:8.18.0", "-n", "demo", "--",
            "curl", "-sf", f"http://phi-4-llm.default.svc.cluster.local/v1/models",
        ],
        text=True,
        stderr=subprocess.STDOUT,
        timeout=120,
    )
    assert "phi" in out.lower() or LLM_MODEL in out


def test_phi4_chat_completion():
    if not os.environ.get("PHI4_AIM_DEPLOYED", ""):
        pytest.skip("Set PHI4_AIM_DEPLOYED=1 after deploy")
    out = subprocess.check_output(
        [
            "kubectl", "run", "phi4-chat-test", "--rm", "-i", "--restart=Never",
            "--image=curlimages/curl:8.18.0", "-n", "demo", "--",
            "sh", "-c",
            f"curl -sf --max-time 180 -X POST http://phi-4-llm.default.svc.cluster.local/v1/chat/completions "
            f"-H 'Content-Type: application/json' "
            f"-d '{{\"model\":\"{LLM_MODEL}\",\"messages\":[{{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}}],"
            f"\"max_tokens\":10,\"temperature\":0}}'",
        ],
        text=True,
        stderr=subprocess.STDOUT,
        timeout=240,
    )
    assert "choices" in out


def test_phi4_tool_calling():
    if not os.environ.get("PHI4_AIM_DEPLOYED", ""):
        pytest.skip("Set PHI4_AIM_DEPLOYED=1 after deploy")
    if not os.environ.get("PHI4_TOOL_CALLING", ""):
        pytest.skip("Set PHI4_TOOL_CALLING=1 after tool-calling spike passes")
    out = subprocess.check_output(
        [
            "kubectl", "run", "phi4-tool-test", "--rm", "-i", "--restart=Never",
            "--image=curlimages/curl:8.18.0", "-n", "demo", "--",
            "sh", "-c",
            f"curl -sf --max-time 180 -X POST http://phi-4-llm.default.svc.cluster.local/v1/chat/completions "
            f"-H 'Content-Type: application/json' "
            f"-d '{{\"model\":\"{LLM_MODEL}\",\"messages\":[{{\"role\":\"user\",\"content\":\"What is 2+2?\"}}],"
            f"\"tools\":[{{\"type\":\"function\",\"function\":{{\"name\":\"calc\",\"description\":\"Calculator\","
            f"\"parameters\":{{\"type\":\"object\",\"properties\":{{\"expr\":{{\"type\":\"string\"}}}}}}}}}}],"
            f"\"max_tokens\":30,\"temperature\":0}}'",
        ],
        text=True,
        stderr=subprocess.STDOUT,
        timeout=240,
    )
    assert "finish_reason" in out
