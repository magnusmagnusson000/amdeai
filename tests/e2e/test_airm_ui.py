"""E2E: AMD Resource Manager UI."""
from __future__ import annotations

import pytest
from playwright.sync_api import Page, expect


@pytest.mark.skipif(not __import__("os").environ.get("E2E_AIRM", ""), reason="Set E2E_AIRM=1")
def test_airm_login(page: Page, domain: str, airm_password: str | None):
    if not airm_password:
        pytest.skip("AIRM credentials not ready")
    page.goto(f"https://airmui.{domain}")
    page.get_by_label("Username", exact=False).or_(page.locator('input[name="username"]')).fill("admin")
    page.get_by_label("Password", exact=False).or_(page.locator('input[type="password"]')).fill(airm_password)
    page.get_by_role("button", name="Sign in").or_(page.get_by_role("button", name="Login")).click()
    expect(page.locator("body")).to_contain_text(/GPU|Radeon|Resource/i, timeout=60000)
