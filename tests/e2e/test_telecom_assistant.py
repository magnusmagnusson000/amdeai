"""Playwright E2E: Telecom Assistant UI and text chat (Client Simulator)."""
from __future__ import annotations

import os
import re
import subprocess
import time

import pytest
import requests
from playwright.sync_api import Page, expect

from telecom_helpers import (
    NAMESPACE,
    RELEASE,
    pod_ready,
    port_forward,
    wait_pod,
)

FRONTEND_URL = os.environ.get("TELECOM_FRONTEND_URL", "http://127.0.0.1:13000")
LIVEKIT_LOCAL_PORT = os.environ.get("TELECOM_LIVEKIT_LOCAL_PORT", "7880")


@pytest.fixture(scope="module")
def telecom_port_forwards(skip_without_telecom):
    """Start frontend + LiveKit port-forwards for the test module."""
    if not os.environ.get("E2E_TELECOM", ""):
        pytest.skip("Set E2E_TELECOM=1")

    procs = []
    for svc, local, remote in [
        (f"svc/aimsb-telecom-assistant-{RELEASE}-frontend", "13000", "3000"),
        (f"svc/{RELEASE}-livekit", LIVEKIT_LOCAL_PORT, "80"),
    ]:
        p = subprocess.Popen(
            ["kubectl", "port-forward", svc, f"{local}:{remote}", "-n", NAMESPACE],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        procs.append(p)
    time.sleep(3)
    try:
        r = requests.get(f"{FRONTEND_URL}/", timeout=15)
        if r.status_code >= 500:
            pytest.skip("frontend not reachable — deploy telecom-assistant first")
    except requests.RequestException as e:
        pytest.skip(f"frontend not reachable: {e}")
    yield
    for p in procs:
        p.terminate()
        p.wait(timeout=10)


@pytest.fixture(scope="module")
def telecom_stack_ready(skip_without_telecom):
    wait_pod("telecom-stt", timeout=900)
    wait_pod("telecom-tts", timeout=900)
    wait_pod("aimsb-telecom-assistant-eai-telecom-agent", timeout=600)
    assert pod_ready("telecom-stt")
    assert pod_ready("telecom-tts")
    assert pod_ready("aimsb-telecom-assistant-eai-telecom-agent")


def test_cpu_speech_endpoints(skip_without_telecom, telecom_stack_ready):
    with port_forward("svc/telecom-stt", 18002, 80):
        stt = requests.get("http://127.0.0.1:18002/v1/models", timeout=15)
        assert stt.status_code == 200
    with port_forward("svc/telecom-tts", 18003, 80):
        tts = requests.get("http://127.0.0.1:18003/v1/models", timeout=15)
        assert tts.status_code == 200


@pytest.mark.usefixtures("telecom_port_forwards", "telecom_stack_ready")
def test_homepage_loads(page: Page):
    page.goto(FRONTEND_URL, wait_until="networkidle", timeout=120000)
    expect(page.locator("h1")).to_contain_text(re.compile(r"Tele.*assist", re.I))


def test_connection_details_api(skip_without_telecom):
    if not os.environ.get("E2E_TELECOM", ""):
        pytest.skip("Set E2E_TELECOM=1")
    wait_pod("aimsb-telecom-assistant-eai-telecom-frontend", timeout=240)
    with port_forward(
        f"svc/aimsb-telecom-assistant-{RELEASE}-frontend", 13000, 3000
    ):
        r = requests.post(
            "http://127.0.0.1:13000/api/connection-details", json={}, timeout=15
        )
        assert r.status_code == 200
        body = r.json()
        assert "participantToken" in body
        assert "ws://" in body.get("serverUrl", "") or "wss://" in body.get(
            "serverUrl", ""
        )


@pytest.mark.usefixtures("telecom_port_forwards", "telecom_stack_ready")
def test_live_badge_and_client_simulator(page: Page):
    page.goto(FRONTEND_URL, wait_until="networkidle", timeout=120000)
    expect(page.get_by_label("Live")).to_be_visible(timeout=90000)
    expect(page.get_by_role("heading", name="Client Simulator")).to_be_visible()
    expect(page.get_by_text("milkyway")).to_be_visible()
    expect(page.get_by_text("mars")).to_be_visible()


@pytest.mark.usefixtures("telecom_port_forwards", "telecom_stack_ready")
def test_tools_panel_toggle(page: Page):
    page.goto(FRONTEND_URL, wait_until="networkidle", timeout=120000)
    expect(page.get_by_label("Live")).to_be_visible(timeout=90000)
    toggle = page.get_by_label("Show tools panel")
    toggle.click()
    expect(page.get_by_role("heading", name="Tool execution history")).to_be_visible()


@pytest.mark.usefixtures("telecom_port_forwards", "telecom_stack_ready")
def test_text_chat_milkyway_passphrase(page: Page):
    """Send passphrase via Client Simulator text input (no microphone)."""
    page.goto(FRONTEND_URL, wait_until="networkidle", timeout=120000)
    expect(page.get_by_label("Live")).to_be_visible(timeout=90000)

    chat_input = page.get_by_placeholder("Type something...")
    expect(chat_input).to_be_enabled(timeout=60000)
    chat_input.fill("My passphrase is milkyway")
    page.get_by_label("Send message").click()

    expect(page.locator("body")).to_contain_text(
        re.compile(r"John|Black|Essential|balance|account", re.I),
        timeout=240000,
    )


@pytest.mark.usefixtures("telecom_port_forwards", "telecom_stack_ready")
def test_mic_mute_controls(page: Page):
    page.goto(FRONTEND_URL, wait_until="networkidle", timeout=120000)
    expect(page.get_by_label("Live")).to_be_visible(timeout=90000)
    mic = page.get_by_label(re.compile(r"Mute microphone|Unmute microphone"))
    mic.click()
    expect(page.get_by_label("Muted")).to_be_visible(timeout=10000)


@pytest.mark.usefixtures("telecom_port_forwards", "telecom_stack_ready")
def test_end_call_button(page: Page):
    page.goto(FRONTEND_URL, wait_until="networkidle", timeout=120000)
    expect(page.get_by_label("Live")).to_be_visible(timeout=90000)
    page.get_by_role("button", name="End call").click()
    expect(page.get_by_role("button", name="Call")).to_be_visible(timeout=15000)
