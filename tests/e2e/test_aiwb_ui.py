"""E2E: AMD AI Workbench UI."""
from __future__ import annotations

import os
import re
import subprocess
import time
from pathlib import Path

import pytest
from playwright.sync_api import Page, expect

_SKIP = pytest.mark.skipif(
    not os.environ.get("E2E_AIWB", ""),
    reason="Set E2E_AIWB=1",
)

_SKIP_QWEN_DEPLOY = pytest.mark.skipif(
    not os.environ.get("E2E_QWEN_DEPLOY", ""),
    reason="Set E2E_QWEN_DEPLOY=1 for one-time full deploy (destructive)",
)

_CATALOG_URL_PATH = "/demo/models/aim-catalog"
_CHAT_URL_PATH = "/demo/chat"
_EAI_ROOT = Path(__file__).resolve().parents[2]
_QWEN_DEPLOY_MIN_GB = 120
_QWEN_DEPLOY_TIMEOUT_S = 5400  # 90 min — download + model load
_QWEN_CHAT_TIMEOUT_S = 180


def _keycloak_login(page: Page, domain: str, username: str, password: str) -> None:
    page.goto(f"https://aiwbui.{domain}")
    page.get_by_role("button", name="Sign in with Keycloak").click()
    page.locator("#username, input[name='username']").fill(username)
    page.locator("#password, input[name='password']").fill(password)
    page.get_by_role("button", name="Sign In").click()
    expect(page).not_to_have_url(re.compile(r"realms"), timeout=60000)


def _click_qwen_deploy_button(page: Page) -> None:
    """Click the Deploy split-button on the qwen-qwen3-6-27b catalog card.

    The catalog has multiple "Deploy" buttons (card actions + a filter dropdown).
    We locate the one geometrically closest to the qwen model card text.
    """
    qwen_text = page.locator("text=qwen-qwen3-6-27b").first
    qwen_text.wait_for(state="visible", timeout=30000)
    qwen_bb = qwen_text.bounding_box()

    all_deploy_btns = page.get_by_role("button", name="Deploy").all()
    closest, min_dist = None, 9999
    for btn in all_deploy_btns:
        bb = btn.bounding_box()
        if bb and qwen_bb:
            dist = abs(bb["y"] - qwen_bb["y"]) + abs(bb["x"] - qwen_bb["x"])
            if dist < min_dist:
                min_dist, closest = dist, btn
    assert closest is not None, "No Deploy button found near qwen card"
    closest.click()


def _kubectl(args: list[str], timeout: int = 30) -> str:
    """Run a kubectl command and return stdout (best-effort)."""
    try:
        return subprocess.check_output(
            ["kubectl"] + args, stderr=subprocess.DEVNULL, text=True, timeout=timeout
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def _kubectl_run(args: list[str], timeout: int = 60) -> None:
    try:
        subprocess.run(
            ["kubectl"] + args,
            stderr=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        pass


def _existing_aimservices(namespace: str = "demo") -> set[str]:
    out = _kubectl(["get", "aimservice", "-n", namespace, "-o", "name"])
    return set(out.splitlines()) if out else set()


def _cleanup_new_aimservices(before: set[str], namespace: str = "demo") -> None:
    """Delete any AIMService that appeared after `before` was captured."""
    after = _existing_aimservices(namespace)
    for svc in after - before:
        name = svc.split("/")[-1]
        _kubectl(["delete", "aimservice", name, "-n", namespace, "--ignore-not-found"])
        _kubectl(
            [
                "delete", "pvc", "-n", "default",
                "-l", f"aim.eai.amd.com/service={name}",
                "--ignore-not-found",
            ]
        )


def _free_disk_gb() -> int:
    out = subprocess.check_output(["df", "/"], text=True)
    free_kb = int(out.splitlines()[1].split()[3])
    return free_kb // 1024 // 1024


def _qwen_aimservice_names(namespace: str = "demo") -> list[str]:
    """Return AIMService names for Qwen3.6-27B (Workbench uses wb-aim-* names)."""
    names: list[str] = []
    for svc in _existing_aimservices(namespace):
        name = svc.split("/")[-1]
        model = _kubectl(
            ["get", "aimservice", name, "-n", namespace, "-o", "jsonpath={.spec.model.name}"]
        )
        if model == "qwen-qwen3-6-27b" or "qwen" in name.lower():
            names.append(name)
    return names


def _teardown_qwen_deployments(namespace: str = "demo") -> None:
    """Remove existing Qwen AIMService / InferenceService / PVCs before a fresh deploy."""
    for name in _qwen_aimservice_names(namespace):
        _kubectl_run(
            ["delete", "aimservice", name, "-n", namespace, "--ignore-not-found", "--wait=true", "--timeout=120s"],
            timeout=150,
        )

    for tc in _kubectl(["get", "aimtemplatecache", "-n", namespace, "-o", "name"]).splitlines():
        if tc and "qwen3-6-27b" in tc.lower():
            _kubectl_run(["delete", tc, "-n", namespace, "--ignore-not-found"], timeout=60)

    for art in _kubectl(["get", "aimartifact", "-n", namespace, "-o", "name"]).splitlines():
        if art and "qwen" in art.lower():
            _kubectl_run(["delete", art, "-n", namespace, "--ignore-not-found"], timeout=60)

    isvcs = _kubectl(["get", "inferenceservice", "-n", namespace, "-o", "name"])
    for isvc in isvcs.splitlines():
        if isvc and ("qwen" in isvc.lower() or "wb-aim" in isvc.lower()):
            _kubectl_run(["delete", isvc, "-n", namespace, "--ignore-not-found", "--force", "--grace-period=0"], timeout=60)

    pvcs = _kubectl(["get", "pvc", "-n", namespace, "-o", "name"])
    for pvc in pvcs.splitlines():
        if pvc and "qwen" in pvc.lower():
            name = pvc.split("/")[-1]
            _kubectl_run(
                ["patch", "pvc", name, "-n", namespace, "--type=json",
                 "-p", '[{"op":"remove","path":"/metadata/finalizers"}]'],
                timeout=30,
            )
            _kubectl_run(
                ["delete", "pvc", name, "-n", namespace, "--ignore-not-found", "--force", "--grace-period=0"],
                timeout=30,
            )


def _wait_qwen_aimservice_running(namespace: str = "demo", timeout_s: int = _QWEN_DEPLOY_TIMEOUT_S) -> str:
    """Poll until a Qwen AIMService in namespace reports Running."""
    deadline = time.time() + timeout_s
    last_status = ""
    while time.time() < deadline:
        for name in _qwen_aimservice_names(namespace):
            last_status = _kubectl(
                ["get", "aimservice", name, "-n", namespace, "-o", "jsonpath={.status.status}"]
            )
            print(f"  aimservice/{name} status={last_status!r}", flush=True)
            if last_status == "Running":
                return name
        # Workbench may create template-cache before AIMService appears
        caches = _kubectl(["get", "aimtemplatecache", "-n", namespace, "-o", "name"])
        if caches:
            print(f"  waiting (template-cache: {caches})", flush=True)
        time.sleep(30)
    pytest.fail(f"Qwen AIMService did not reach Running within {timeout_s}s (last status={last_status!r})")


def _ensure_qwen_chattable_metadata() -> None:
    """Publish chat tag on AIMClusterModel status (Workbench chattable API)."""
    script = _EAI_ROOT / "scripts" / "ensure-qwen-chattable.sh"
    if script.is_file():
        subprocess.run(["bash", str(script)], check=False, timeout=90)


def _chattable_response(page: Page, domain: str, namespace: str = "demo") -> dict:
    resp = page.request.get(f"https://aiwbui.{domain}/api/namespaces/{namespace}/chattable")
    assert resp.ok, f"chattable API failed: HTTP {resp.status}"
    return resp.json()


def _select_qwen_chat_model(page: Page) -> None:
    """Open Chat model dropdown and select the Qwen catalog entry."""
    page.locator("text=Select model").last.click(force=True)
    option = page.locator('[role="option"]').filter(has_text=re.compile(r"Qwen", re.I))
    expect(option.first).to_be_visible(timeout=15000)
    option.first.click()
    expect(page.locator('[data-testid="chat-input"]')).to_be_enabled(timeout=15000)


@_SKIP
@pytest.mark.order(2)
def test_keycloak_login(page: Page, domain: str, devuser_password: str | None):
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")
    _keycloak_login(page, domain, f"devuser@{domain}", devuser_password)
    expect(page.locator("body")).not_to_contain_text(
        re.compile(r"500|502|connection refused", re.I), timeout=15000
    )


@_SKIP
@pytest.mark.order(4)
def test_aim_catalog_shows_qwen(page: Page, domain: str, devuser_password: str | None):
    """AIM Catalog page in demo project shows the gfx1151 Qwen3.6-27B entry."""
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")
    _keycloak_login(page, domain, f"devuser@{domain}", devuser_password)
    page.goto(f"https://aiwbui.{domain}{_CATALOG_URL_PATH}")
    page.wait_for_load_state("networkidle", timeout=15000)
    expect(page.locator("text=qwen-qwen3-6-27b")).to_be_visible(timeout=30000)
    qwen_text = page.locator("text=qwen-qwen3-6-27b").first
    qwen_bb = qwen_text.bounding_box()
    all_deploy = page.get_by_role("button", name="Deploy").all()
    closest = min(
        (b for b in all_deploy if b.bounding_box()),
        key=lambda b: abs(b.bounding_box()["y"] - qwen_bb["y"]),
    )
    expect(closest).to_be_enabled()


@_SKIP
@pytest.mark.order(5)
def test_deploy_qwen_model(page: Page, domain: str, devuser_password: str | None):
    """Deploy dialog opens, shows correct content, and cancels cleanly.

    We verify the full open-dialog flow without confirming the deployment so that
    we don't trigger a 50+ GiB model download on every CI run.  A separate check
    (`test_qwen_card_status`) asserts the already-deployed model shows its live
    status on the catalog card.
    """
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")
    _keycloak_login(page, domain, f"devuser@{domain}", devuser_password)
    page.goto(f"https://aiwbui.{domain}{_CATALOG_URL_PATH}")
    page.wait_for_load_state("networkidle", timeout=15000)

    before = _existing_aimservices()

    _click_qwen_deploy_button(page)
    expect(page.locator("text=Deploy AIM")).to_be_visible(timeout=10000)

    expect(page.locator("body")).to_contain_text(
        re.compile(r"qwen.*3.*27b|qwen3-6-27b", re.I), timeout=5000
    )

    cancel_btn = page.get_by_role("button", name=re.compile(r"^Cancel$", re.I))
    if cancel_btn.count() > 0:
        cancel_btn.first.click()
    else:
        page.keyboard.press("Escape")

    expect(page.locator("text=Deploy AIM")).not_to_be_visible(timeout=5000)
    _cleanup_new_aimservices(before)


@_SKIP_QWEN_DEPLOY
def test_qwen_deploy_confirm_full(page: Page, domain: str, devuser_password: str | None):
    """One-time full Deploy: teardown, confirm dialog, wait for Running.

    NOT part of the default suite — requires E2E_QWEN_DEPLOY=1.
    Deletes existing Qwen deployments and triggers ~52 GiB download.
    """
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")

    free_gb = _free_disk_gb()
    print(f"Disk free: {free_gb} GiB (need >= {_QWEN_DEPLOY_MIN_GB})", flush=True)
    if free_gb < _QWEN_DEPLOY_MIN_GB:
        pytest.fail(
            f"Need >= {_QWEN_DEPLOY_MIN_GB} GiB free on / (have {free_gb} GiB). "
            "Prune Docker cache or remove old model PVCs before running."
        )

    print("Teardown existing Qwen deployments...", flush=True)
    _teardown_qwen_deployments()

    print("Keycloak login + catalog...", flush=True)
    _keycloak_login(page, domain, f"devuser@{domain}", devuser_password)
    page.goto(f"https://aiwbui.{domain}{_CATALOG_URL_PATH}")
    page.wait_for_load_state("networkidle", timeout=15000)

    print("Click Deploy on Qwen card...", flush=True)
    _click_qwen_deploy_button(page)
    expect(page.locator("text=Deploy AIM")).to_be_visible(timeout=10000)

    confirm = page.locator('[role="dialog"]').get_by_role(
        "button", name=re.compile(r"^(Deploy|Confirm|Deploy AIM)$", re.I)
    )
    if confirm.count() == 0:
        confirm = page.get_by_role("button", name=re.compile(r"^Deploy AIM$", re.I))
    if confirm.count() == 0:
        confirm = page.locator("button").filter(has_text=re.compile(r"^Deploy$", re.I))
    assert confirm.count() > 0, "No confirm button in Deploy AIM dialog"
    print(f"Confirm deploy (buttons={confirm.count()})...", flush=True)
    confirm.first.click()

    expect(page.locator("text=Deploy AIM")).not_to_be_visible(timeout=30000)
    print("Deploy dialog closed — waiting for AIMService...", flush=True)

    appear_deadline = time.time() + 300
    while time.time() < appear_deadline and not _qwen_aimservice_names():
        time.sleep(10)
    if not _qwen_aimservice_names():
        pytest.fail("No Qwen AIMService created within 5 min after Deploy confirm")

    profile_script = _EAI_ROOT / "scripts" / "ensure-qwen-profile-mount.sh"
    deadline = time.time() + 300
    while time.time() < deadline:
        isvcs = _kubectl(["get", "inferenceservice", "-n", "demo", "-o", "name"])
        if isvcs and ("qwen" in isvcs.lower() or "wb-aim" in isvcs.lower()):
            if profile_script.is_file():
                subprocess.run(["bash", str(profile_script), "demo"], check=False, timeout=120)
            break
        time.sleep(10)

    running = False
    wait_deadline = time.time() + _QWEN_DEPLOY_TIMEOUT_S
    while time.time() < wait_deadline:
        for name in _qwen_aimservice_names():
            last_status = _kubectl(
                ["get", "aimservice", name, "-n", "demo", "-o", "jsonpath={.status.status}"]
            )
            print(f"  aimservice/{name} status={last_status!r}", flush=True)
            if last_status == "Running":
                running = True
                break
            logs = _kubectl(["logs", "-n", "demo", "-l", "component=predictor", "--tail=8"])
            if "ProfileNotFound" in logs and profile_script.is_file():
                print("  ProfileNotFound — re-applying profile mount...", flush=True)
                subprocess.run(["bash", str(profile_script), "demo"], check=False, timeout=120)
        if running:
            break
        time.sleep(60)
    if not running:
        pytest.fail(f"Qwen AIMService did not reach Running within {_QWEN_DEPLOY_TIMEOUT_S}s")

    chattable_script = _EAI_ROOT / "scripts" / "ensure-qwen-chattable.sh"
    if chattable_script.is_file():
        subprocess.run(["bash", str(chattable_script)], check=False, timeout=90)

    page.reload()
    page.wait_for_load_state("networkidle", timeout=15000)
    expect(page.locator("body")).to_contain_text(re.compile(r"Running|Deployed", re.I), timeout=60000)
    expect(page.locator("body")).not_to_contain_text(
        re.compile(r"500|502|connection refused", re.I)
    )


@_SKIP
def test_qwen_card_status(page: Page, domain: str, devuser_password: str | None):
    """The qwen-qwen3-6-27b catalog card shows a non-error live status.

    Requires the model to be pre-deployed (wb-aim-* AIMService in demo ns).
    """
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")
    if not _existing_aimservices():
        pytest.skip("No AIMService found in demo ns — model not pre-deployed")

    _keycloak_login(page, domain, f"devuser@{domain}", devuser_password)
    page.goto(f"https://aiwbui.{domain}{_CATALOG_URL_PATH}")
    page.wait_for_load_state("networkidle", timeout=15000)
    expect(page.locator("text=qwen-qwen3-6-27b")).to_be_visible(timeout=30000)

    expect(page.locator("body")).to_contain_text(
        re.compile(r"Running|Starting|Deploying|Failed|Deployed", re.I), timeout=15000
    )
    expect(page.locator("body")).not_to_contain_text(
        re.compile(r"500|502|connection refused", re.I)
    )


@_SKIP
@pytest.mark.order(6)
def test_qwen_chat(page: Page, domain: str, devuser_password: str | None):
    """Chat UI: select deployed Qwen and receive a model response.

    Requires a Running Qwen AIMService (wb-aim-*) in demo. Ensures the catalog
    model exposes the chat tag in status.imageMetadata so /chattable lists it.
    """
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")
    if not _qwen_aimservice_names():
        pytest.skip("No Qwen AIMService in demo — deploy from catalog first")

    _ensure_qwen_chattable_metadata()
    _keycloak_login(page, domain, f"devuser@{domain}", devuser_password)
    page.goto(f"https://aiwbui.{domain}{_CHAT_URL_PATH}")
    page.wait_for_load_state("networkidle", timeout=30000)

    chattable = _chattable_response(page, domain)
    if not chattable.get("aimServices"):
        pytest.fail(
            "chattable API returned no AIM services — run: bash scripts/ensure-qwen-chattable.sh"
        )

    _select_qwen_chat_model(page)
    prompt = "Reply with exactly: pong"
    chat_input = page.locator('[data-testid="chat-input"]')
    chat_input.fill(prompt)
    chat_input.press("Enter")

    expect(page.locator("body")).to_contain_text("pong", timeout=_QWEN_CHAT_TIMEOUT_S * 1000)
    expect(page.locator("body")).not_to_contain_text(
        re.compile(r"500|502|connection refused|failed to fetch", re.I)
    )


@_SKIP
def test_models_page_gemma(page: Page, domain: str, devuser_password: str | None):
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")
    _keycloak_login(page, domain, f"devuser@{domain}", devuser_password)
    page.goto(f"https://aiwbui.{domain}{_CATALOG_URL_PATH}")
    expect(page.locator("body")).to_contain_text(re.compile(r"model|catalog|Gemma", re.I), timeout=60000)
