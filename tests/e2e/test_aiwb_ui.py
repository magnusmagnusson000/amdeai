"""E2E: AMD AI Workbench UI."""
from __future__ import annotations

import re

import pytest
from playwright.sync_api import Page, expect


def _keycloak_login(page: Page, domain: str, username: str, password: str) -> None:
    page.goto(f"https://aiwbui.{domain}")
    page.get_by_role("button", name="Sign in with Keycloak").click()
    page.locator("#username, input[name='username']").fill(username)
    page.locator("#password, input[name='password']").fill(password)
    page.get_by_role("button", name="Sign In").click()
    expect(page).not_to_have_url(re.compile(r"realms"), timeout=60000)


@pytest.mark.skipif(not __import__("os").environ.get("E2E_AIWB", ""), reason="Set E2E_AIWB=1")
def test_keycloak_login(page: Page, domain: str, devuser_password: str | None):
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")
    _keycloak_login(page, domain, f"devuser@{domain}", devuser_password)


@pytest.mark.skipif(not __import__("os").environ.get("E2E_AIWB", ""), reason="Set E2E_AIWB=1")
def test_models_page_gemma(page: Page, domain: str, devuser_password: str | None):
    if not devuser_password:
        pytest.skip("DevUser credentials not ready")
    _keycloak_login(page, domain, f"devuser@{domain}", devuser_password)
    page.goto(f"https://aiwbui.{domain}/models")
    expect(page.locator("body")).to_contain_text(re.compile(r"model|catalog|Gemma", re.I), timeout=60000)
