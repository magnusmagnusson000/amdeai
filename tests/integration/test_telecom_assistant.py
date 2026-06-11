"""Integration tests for Telecom Assistant blueprint on gfx1151 EAI cluster."""
from __future__ import annotations

import io
import os
import struct
import wave

import pytest
import requests

from telecom_helpers import (
    NAMESPACE,
    RELEASE,
    agent_env,
    check_gemma_health,
    deployment_replicas,
    gemma_base_url,
    pod_ready,
    port_forward,
    wait_pod,
)

pytestmark = pytest.mark.usefixtures("skip_without_telecom")


def test_namespace_exists():
    import subprocess

    out = subprocess.check_output(["kubectl", "get", "namespace", NAMESPACE], text=True)
    assert NAMESPACE in out


def test_livekit_running():
    wait_pod(f"{RELEASE}-livekit", timeout=120)
    assert pod_ready(f"{RELEASE}-livekit")


def test_postgres_redis_running():
    wait_pod("aimsb-telecom-assistant-eai-telecom-postgres", timeout=180)
    wait_pod("aimsb-telecom-assistant-eai-telecom-redis", timeout=180)
    assert pod_ready("aimsb-telecom-assistant-eai-telecom-postgres")
    assert pod_ready("aimsb-telecom-assistant-eai-telecom-redis")


def test_cpu_speech_services_running():
    wait_pod("telecom-stt", timeout=900)
    wait_pod("telecom-tts", timeout=900)
    assert pod_ready("telecom-stt")
    assert pod_ready("telecom-tts")


def test_qwen_gpu_speech_disabled():
    assert deployment_replicas("qwen-asr-eai-telecom") == 0
    assert deployment_replicas("qwen-tts-eai-telecom") == 0


def test_agent_uses_cpu_speech_urls():
    wait_pod("aimsb-telecom-assistant-eai-telecom-agent", timeout=600)
    stt_url = agent_env("STT_BASE_URL")
    tts_url = agent_env("TTS_BASE_URL")
    assert stt_url == "http://telecom-stt/v1"
    assert tts_url == "http://telecom-tts/v1"
    assert "qwen" not in (stt_url or "").lower()
    assert "qwen" not in (tts_url or "").lower()


def test_bssgateway_health():
    wait_pod("aimsb-telecom-assistant-eai-telecom-bssgateway", timeout=180)

    with port_forward(
        f"svc/aimsb-telecom-assistant-{RELEASE}-bssgateway", 18001, 8001
    ):
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


def test_chromadb_heartbeat():
    wait_pod(f"{RELEASE}-chromadb", timeout=240)

    with port_forward(f"svc/{RELEASE}-chromadb", 18000, 8000):
        r = requests.get("http://127.0.0.1:18000/api/v2/heartbeat", timeout=15)
        assert r.status_code == 200


def test_embedding_models():
    wait_pod(f"{RELEASE}-embedding", timeout=360)

    with port_forward(f"svc/{RELEASE}-embedding", 17997, 7997):
        r = requests.get("http://127.0.0.1:17997/models", timeout=30)
        assert r.status_code == 200


def test_gemma_llm_bridge():
    """LLM for telecom is host Gemma (also reachable via demo namespace Service)."""
    check_gemma_health()
    base = gemma_base_url()
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


def test_cpu_stt_health_and_models():
    wait_pod("telecom-stt", timeout=900)

    with port_forward("svc/telecom-stt", 18002, 80):
        health = requests.get("http://127.0.0.1:18002/health", timeout=15)
        assert health.status_code == 200
        assert health.json().get("status") == "ok"

        r = requests.get("http://127.0.0.1:18002/v1/models", timeout=15)
        assert r.status_code == 200
        data = r.json()
        assert data.get("object") == "list"
        assert any(m.get("id") == "whisper-1" for m in data.get("data", []))


def _make_test_wav(text: str = "silence") -> bytes:
    """Minimal WAV with ~1s silence for STT smoke test."""
    del text
    buf = io.BytesIO()
    sample_rate = 16000
    frames = struct.pack("<" + "h" * sample_rate, *([0] * sample_rate))
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(frames)
    return buf.getvalue()


def test_cpu_stt_transcription():
    wait_pod("telecom-stt", timeout=900)

    with port_forward("svc/telecom-stt", 18002, 80):
        r = requests.post(
            "http://127.0.0.1:18002/v1/audio/transcriptions",
            files={"file": ("test.wav", _make_test_wav(), "audio/wav")},
            data={"model": "whisper-1"},
            timeout=120,
        )
        assert r.status_code == 200
        assert "text" in r.json()


def test_cpu_tts_health_and_models():
    wait_pod("telecom-tts", timeout=900)

    with port_forward("svc/telecom-tts", 18003, 80):
        health = requests.get("http://127.0.0.1:18003/health", timeout=15)
        assert health.status_code == 200
        assert health.json().get("status") == "ok"

        r = requests.get("http://127.0.0.1:18003/v1/models", timeout=15)
        assert r.status_code == 200
        data = r.json()
        assert data.get("object") == "list"
        assert any(m.get("id") == "kokoro-82m" for m in data.get("data", []))


def test_cpu_tts_speech():
    wait_pod("telecom-tts", timeout=900)

    with port_forward("svc/telecom-tts", 18003, 80):
        for fmt in ("pcm", "mp3"):
            r = requests.post(
                "http://127.0.0.1:18003/v1/audio/speech",
                json={
                    "model": "kokoro-82m",
                    "input": "Hello from telecom assistant.",
                    "voice": "Aiden",
                    "response_format": fmt,
                },
                timeout=120,
            )
            assert r.status_code == 200, f"{fmt} failed: {r.text}"
            assert len(r.content) > 1000


def test_frontend_connection_api():
    wait_pod("aimsb-telecom-assistant-eai-telecom-frontend", timeout=240)

    with port_forward(
        f"svc/aimsb-telecom-assistant-{RELEASE}-frontend", 13000, 3000
    ):
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


def test_agent_running():
    wait_pod("aimsb-telecom-assistant-eai-telecom-agent", timeout=600)
    assert pod_ready("aimsb-telecom-assistant-eai-telecom-agent")
