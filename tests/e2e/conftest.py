"""Playwright fixtures for EAI web UIs."""
from __future__ import annotations

import base64
import subprocess

import pytest
from playwright.sync_api import Browser, BrowserContext, Page


@pytest.fixture(scope="session")
def argocd_password() -> str | None:
    try:
        raw = subprocess.check_output(
            [
                "kubectl",
                "get",
                "secret",
                "argocd-initial-admin-secret",
                "-n",
                "argocd",
                "-o",
                "jsonpath={.data.password}",
            ],
            text=True,
        )
        return base64.b64decode(raw).decode() if raw else None
    except subprocess.CalledProcessError:
        return None


@pytest.fixture(scope="session")
def airm_password() -> str | None:
    try:
        raw = subprocess.check_output(
            [
                "kubectl",
                "get",
                "secret",
                "airm-user-credentials",
                "-n",
                "airm",
                "-o",
                "jsonpath={.data.USER_PASSWORD}",
            ],
            text=True,
        )
        return base64.b64decode(raw).decode() if raw else None
    except subprocess.CalledProcessError:
        return None


@pytest.fixture(scope="session")
def devuser_password() -> str | None:
    try:
        raw = subprocess.check_output(
            [
                "kubectl",
                "get",
                "secret",
                "airm-realm-credentials",
                "-n",
                "keycloak",
                "-o",
                "jsonpath={.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}",
            ],
            text=True,
        )
        return base64.b64decode(raw).decode() if raw else None
    except subprocess.CalledProcessError:
        return None


@pytest.fixture(scope="session")
def keycloak_password() -> str | None:
    try:
        raw = subprocess.check_output(
            [
                "kubectl",
                "get",
                "secret",
                "keycloak-credentials",
                "-n",
                "keycloak",
                "-o",
                "jsonpath={.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}",
            ],
            text=True,
        )
        return base64.b64decode(raw).decode() if raw else None
    except subprocess.CalledProcessError:
        return None


@pytest.fixture
def browser_context(browser: Browser) -> BrowserContext:
    ctx = browser.new_context(ignore_https_errors=True)
    yield ctx
    ctx.close()


@pytest.fixture
def page(browser_context: BrowserContext) -> Page:
    p = browser_context.new_page()
    yield p
    p.close()
