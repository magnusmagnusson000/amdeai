"""E2E: AMD Resource Manager UI."""
from __future__ import annotations

import re

import pytest
from playwright.sync_api import Page, expect


@pytest.mark.skipif(not __import__("os").environ.get("E2E_AIRM", ""), reason="Set E2E_AIRM=1")
@pytest.mark.order(3)
def test_airm_login(page: Page, domain: str, devuser_password: str | None):
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")
    page.goto(f"https://airmui.{domain}")
    page.get_by_role("button", name="Sign in with Keycloak").click()
    page.locator("#username, input[name='username']").fill(f"devuser@{domain}")
    page.locator("#password, input[name='password']").fill(devuser_password)
    page.get_by_role("button", name="Sign In").click()
    expect(page).not_to_have_url(re.compile(r"realms"), timeout=60000)
    expect(page.locator("body")).to_contain_text(
        re.compile(r"GPU|Radeon|Resource|Project", re.I), timeout=60000
    )
