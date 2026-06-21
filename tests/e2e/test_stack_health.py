"""E2E pre-flight: cluster health before Playwright UI tests."""
from __future__ import annotations

import os
import subprocess

import pytest

_SKIP = pytest.mark.skipif(
    not os.environ.get("E2E_STACK", ""),
    reason="Set E2E_STACK=1",
)


def _kubectl(args: list[str]) -> str:
    return subprocess.check_output(
        ["kubectl"] + args, stderr=subprocess.STDOUT, text=True
    ).strip()


@_SKIP
@pytest.mark.order(1)
def test_stack_cluster_ready(skip_without_k8s):
    """Node Ready, GPU capacity, gateway programmed, core UI namespaces healthy."""
    nodes = _kubectl(["get", "nodes", "-o", "jsonpath={.items[0].status.conditions[?(@.type=='Ready')].status}"])
    assert nodes == "True", f"Node not Ready: {nodes}"

    gpu = _kubectl(["get", "nodes", "-o", "jsonpath={.items[0].status.capacity.amd\\.com/gpu}"])
    assert gpu and int(gpu) >= 1, f"Expected amd.com/gpu >= 1, got {gpu!r}"

    gw_status = _kubectl(
        [
            "get",
            "gateway",
            "-n",
            "envoy-gateway-system",
            "-o",
            "jsonpath={.items[0].status.conditions[?(@.type=='Programmed')].status}",
        ]
    )
    assert gw_status == "True", f"Gateway not Programmed: {gw_status!r}"

    for ns in ("keycloak", "aiwb", "airm"):
        phase = _kubectl(
            [
                "get",
                "pods",
                "-n",
                ns,
                "--field-selector=status.phase!=Running,status.phase!=Succeeded",
                "-o",
                "name",
            ]
        )
        bad = [p for p in phase.splitlines() if p.strip()]
        assert not bad, f"Unhealthy pods in {ns}: {bad}"

    out = _kubectl(["get", "secret", "airm-realm-credentials", "-n", "keycloak", "-o", "name"])
    assert "airm-realm-credentials" in out, "Keycloak devuser secret missing"


@_SKIP
@pytest.mark.order(1)
def test_stack_qwen_catalog_ready(skip_without_k8s):
    """AIM catalog CRs present and template Ready (Workbench Deploy button)."""
    template = "qwen3-6-27b-r9700-gfx1151-latency"
    try:
        status = _kubectl(
            ["get", "aimclusterservicetemplate", template, "-o", "jsonpath={.status.status}"]
        )
    except subprocess.CalledProcessError:
        pytest.fail(
            f"AIMClusterServiceTemplate {template} not found — "
            "run: CATALOG_ONLY=1 bash scripts/10-qwen3-6-27b.sh"
        )
    assert status == "Ready", (
        f"Template status={status!r}, expected Ready — "
        "run: bash scripts/03b-gfx1151-aim-labels.sh && CATALOG_ONLY=1 bash scripts/10-qwen3-6-27b.sh"
    )

    matching = _kubectl(
        [
            "get",
            "aimclusterprofile",
            template,
            "-o",
            "jsonpath={.status.matchingNodes}",
        ]
    )
    assert matching and int(matching) >= 1, (
        f"Profile matchingNodes={matching!r} — run: bash scripts/03b-gfx1151-aim-labels.sh"
    )


@_SKIP
@pytest.mark.order(1)
def test_stack_diffusiongemma_catalog_ready(skip_without_k8s):
    """DiffusionGemma catalog CRs present when E2E_DIFFUSIONGEMMA=1."""
    if not os.environ.get("E2E_DIFFUSIONGEMMA", ""):
        pytest.skip("Set E2E_DIFFUSIONGEMMA=1")
    template = "diffusiongemma-26b-r9700-gfx1151-latency"
    try:
        status = _kubectl(
            ["get", "aimclusterservicetemplate", template, "-o", "jsonpath={.status.status}"]
        )
    except subprocess.CalledProcessError:
        pytest.fail(
            f"AIMClusterServiceTemplate {template} not found — "
            "run: CATALOG_ONLY=1 bash scripts/12-diffusiongemma-26b.sh"
        )
    assert status == "Ready", (
        f"Template status={status!r}, expected Ready — "
        "run: CATALOG_ONLY=1 bash scripts/12-diffusiongemma-26b.sh && "
        "bash scripts/fix-diffusiongemma-template-discovery.sh"
    )


@_SKIP
@pytest.mark.order(1)
def test_stack_https_smoke(domain: str, skip_without_k8s):
    """AI Workbench and AIRM return 200/307 over HTTPS (not 403/5xx)."""
    import ssl
    import urllib.error
    import urllib.request

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    for host in (f"aiwbui.{domain}", f"airmui.{domain}"):
        url = f"https://{host}/"
        req = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
                code = resp.status
        except urllib.error.HTTPError as exc:
            code = exc.code
        assert code in (200, 307, 302), f"{url} returned HTTP {code} (run: bash scripts/fix-web-uis.sh)"
