"""E2E: Argo CD UI (requires port-forward to localhost:8443)."""
from __future__ import annotations

import re

import pytest
from playwright.sync_api import Page, expect


@pytest.mark.skipif(
    not __import__("os").environ.get("E2E_ARGOCD", ""),
    reason="Set E2E_ARGOCD=1 and kubectl port-forward svc/argocd-server -n argocd 8443:443",
)
def test_login(page: Page, argocd_password: str | None):
    if not argocd_password:
        pytest.skip("ArgoCD secret not available")
    page.goto("https://localhost:8443")
    page.get_by_label("Username").fill("admin")
    page.get_by_label("Password").fill(argocd_password)
    page.get_by_role("button", name="Sign In").click()
    expect(page).to_have_url(re.compile(r"applications"), timeout=30000)


@pytest.mark.skipif(not __import__("os").environ.get("E2E_ARGOCD", ""), reason="E2E_ARGOCD not set")
def test_applications_visible(page: Page, argocd_password: str | None):
    if not argocd_password:
        pytest.skip("ArgoCD secret not available")
    page.goto("https://localhost:8443")
    page.get_by_label("Username").fill("admin")
    page.get_by_label("Password").fill(argocd_password)
    page.get_by_role("button", name="Sign In").click()
    expect(page.locator(".application-status-panel, [class*='application']").first).to_be_visible(
        timeout=30000
    )
