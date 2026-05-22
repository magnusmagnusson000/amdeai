"""E2E: AMD AI Workbench UI."""
from __future__ import annotations

import pytest
from playwright.sync_api import Page, expect


@pytest.mark.skipif(not __import__("os").environ.get("E2E_AIWB", ""), reason="Set E2E_AIWB=1")
def test_keycloak_login(page: Page, domain: str, keycloak_password: str | None):
    if not keycloak_password:
        pytest.skip("Keycloak credentials not ready")
    page.goto(f"https://aiwbui.{domain}")
    page.locator("#username, input[name='username']").fill("silogen-admin")
    page.locator("#password, input[name='password']").fill(keycloak_password)
    page.get_by_role("button", name="Sign In").click()
    expect(page).not_to_have_url(/realms/, timeout=60000)


@pytest.mark.skipif(not __import__("os").environ.get("E2E_AIWB", ""), reason="Set E2E_AIWB=1")
def test_models_page_gemma(page: Page, domain: str, keycloak_password: str | None):
    if not keycloak_password:
        pytest.skip("Keycloak credentials not ready")
    page.goto(f"https://aiwbui.{domain}")
    page.locator("#username, input[name='username']").fill("silogen-admin")
    page.locator("#password, input[name='password']").fill(keycloak_password)
    page.get_by_role("button", name="Sign In").click()
    page.goto(f"https://aiwbui.{domain}/models")
    expect(page.locator("body")).to_contain_text("Gemma", timeout=60000)
