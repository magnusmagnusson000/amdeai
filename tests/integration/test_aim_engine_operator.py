"""Integration: AIM Engine operator and AIMModel CR."""
from __future__ import annotations

import subprocess
import time

import pytest


def test_operator_pod_ready(skip_without_k8s):
    r = subprocess.run(
        ["kubectl", "get", "pods", "-n", "aim-system", "-o", "jsonpath={.items[*].status.phase}"],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0 or not r.stdout:
        pytest.skip("aim-system not deployed")
    assert "Running" in r.stdout


def test_aimmodel_cr_accepted(skip_without_k8s):
    manifest = """
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMModel
metadata:
  name: eai-test-model
  namespace: default
spec:
  displayName: EAI Test
  endpoint:
    url: "http://127.0.0.1:8080"
    type: OpenAI
  modelId: test
  capabilities: [chat]
"""
    subprocess.run(["kubectl", "delete", "aimmodel", "eai-test-model", "--ignore-not-found"], check=False)
    subprocess.run(["kubectl", "apply", "-f", "-"], input=manifest, text=True, check=True)
    time.sleep(2)
    r = subprocess.run(
        ["kubectl", "get", "aimmodel", "eai-test-model"],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0
    subprocess.run(["kubectl", "delete", "aimmodel", "eai-test-model", "--ignore-not-found"], check=False)
