"""Performance tests for Qwen/Qwen3.6-35B-A3B (MoE) on gfx1151 via vLLM.

Measures TTFT, sustained throughput, latency distribution across prompt sizes,
and concurrent request handling against the OpenAI-compatible /v1 endpoint.

All tests require PERF_ENDPOINT to be set. They are skipped otherwise so they
never run accidentally in CI or stack validation.

Usage:
    PERF_ENDPOINT=https://<node>/<path> \\
    PERF_MODEL=Qwen/Qwen3.6-35B-A3B \\
        pytest tests/perf/test_qwen_moe_perf.py -v -s

    # Or via NodePort if exposed:
    PERF_ENDPOINT=http://192.168.32.13:30402 \\
    PERF_MODEL=Qwen/Qwen3.6-35B-A3B \\
        pytest tests/perf/test_qwen_moe_perf.py -v -s

Environment variables:
    PERF_ENDPOINT  Base URL for the vLLM /v1 API (required — no trailing slash)
    PERF_MODEL     Model ID to use in requests (default: Qwen/Qwen3.6-35B-A3B)
    PERF_TIMEOUT   Per-request timeout in seconds (default: 300)
"""
from __future__ import annotations

import json
import os
import statistics
import threading
import time
from typing import Generator

import httpx
import pytest

_ENDPOINT = os.environ.get("PERF_ENDPOINT", "").rstrip("/")
_MODEL = os.environ.get("PERF_MODEL", "Qwen/Qwen3.6-35B-A3B")
_TIMEOUT = int(os.environ.get("PERF_TIMEOUT", "300"))

_SKIP = pytest.mark.skipif(
    not _ENDPOINT,
    reason="Set PERF_ENDPOINT=http(s)://<host>/<path> to run performance tests",
)

# Chat template kwargs to disable thinking mode (faster, more predictable tokens)
_NO_THINK = {"enable_thinking": False}

# Thresholds — conservative baselines for a single R9700 gfx1151 node
_TTFT_MAX_S = 10.0          # max acceptable time-to-first-token (seconds)
_THROUGHPUT_MIN_TOKS = 8.0  # min acceptable sustained tokens/second
_P95_LATENCY_MAX_S = 120.0  # max P95 end-to-end latency across all prompt sizes


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _chat(
    prompt: str,
    max_tokens: int = 50,
    stream: bool = False,
) -> httpx.Response:
    payload = {
        "model": _MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "chat_template_kwargs": _NO_THINK,
    }
    url = f"{_ENDPOINT}/v1/chat/completions"
    if stream:
        return httpx.post(url, json=payload, timeout=_TIMEOUT, headers={"Accept": "text/event-stream"})
    return httpx.post(url, json=payload, timeout=_TIMEOUT)


def _stream_chat(prompt: str, max_tokens: int = 80) -> Generator[str, None, None]:
    """Yield SSE data lines from a streaming chat completion."""
    payload = {
        "model": _MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
        "chat_template_kwargs": _NO_THINK,
    }
    url = f"{_ENDPOINT}/v1/chat/completions"
    with httpx.stream("POST", url, json=payload, timeout=_TIMEOUT) as resp:
        resp.raise_for_status()
        for line in resp.iter_lines():
            if line.startswith("data: ") and line != "data: [DONE]":
                yield line[len("data: "):]


def _token_count(response: httpx.Response) -> int:
    try:
        return response.json()["usage"]["completion_tokens"]
    except (KeyError, json.JSONDecodeError):
        return 0


def _make_prompt(approx_tokens: int) -> str:
    """Return a prompt whose completion will exercise roughly approx_tokens of context."""
    word = "silicon "
    return (word * (approx_tokens // 2)).strip() + " — summarise in one sentence."


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@_SKIP
def test_health_check():
    """Endpoint responds to /health before any perf test."""
    resp = httpx.get(f"{_ENDPOINT}/health", timeout=30)
    assert resp.status_code in (200, 404), (
        f"/health returned unexpected status {resp.status_code} — is the endpoint reachable?"
    )


@_SKIP
def test_models_endpoint():
    """The model ID is present in /v1/models."""
    resp = httpx.get(f"{_ENDPOINT}/v1/models", timeout=30)
    resp.raise_for_status()
    model_ids = [m["id"] for m in resp.json().get("data", [])]
    assert any(_MODEL in mid for mid in model_ids), (
        f"Model {_MODEL!r} not found in /v1/models. Found: {model_ids}"
    )


@_SKIP
def test_ttft_short_prompt():
    """Time-to-first-token for a short prompt must be under threshold.

    Uses streaming so we capture the timestamp of the first chunk, not the
    full completion time.
    """
    prompt = "Reply with exactly: ready"
    t_start = time.perf_counter()
    first_token_time: float | None = None
    total_chunks = 0

    for chunk_json in _stream_chat(prompt, max_tokens=20):
        now = time.perf_counter()
        if first_token_time is None:
            first_token_time = now - t_start
        total_chunks += 1
        try:
            data = json.loads(chunk_json)
            delta = data["choices"][0].get("delta", {})
            if delta.get("content"):
                pass  # token received
        except (json.JSONDecodeError, KeyError, IndexError):
            pass

    assert first_token_time is not None, "No streaming tokens received"
    print(f"\n  TTFT: {first_token_time:.2f}s  (threshold: {_TTFT_MAX_S}s)")
    assert first_token_time <= _TTFT_MAX_S, (
        f"TTFT {first_token_time:.2f}s exceeds threshold {_TTFT_MAX_S}s"
    )


@_SKIP
def test_throughput_sustained():
    """Sustained throughput over 5 sequential completions.

    Sends 5 chat requests (50 tokens each) back-to-back and measures
    aggregate tokens/second. Target: >= 8 tok/s on a single R9700.
    """
    n_requests = 5
    tokens_per_request = 50
    prompt = "Write a short technical description of mixture-of-experts architecture."

    t_start = time.perf_counter()
    total_tokens = 0
    for i in range(n_requests):
        resp = _chat(prompt, max_tokens=tokens_per_request)
        resp.raise_for_status()
        toks = _token_count(resp)
        total_tokens += toks
        print(f"  request {i + 1}/{n_requests}: {toks} tokens", flush=True)

    elapsed = time.perf_counter() - t_start
    toks_per_sec = total_tokens / elapsed if elapsed > 0 else 0

    print(f"\n  Throughput: {toks_per_sec:.2f} tok/s over {n_requests} requests "
          f"({total_tokens} tokens in {elapsed:.1f}s)")
    print(f"  Threshold: >= {_THROUGHPUT_MIN_TOKS} tok/s")

    assert toks_per_sec >= _THROUGHPUT_MIN_TOKS, (
        f"Throughput {toks_per_sec:.2f} tok/s below threshold {_THROUGHPUT_MIN_TOKS} tok/s"
    )


@_SKIP
def test_latency_distribution():
    """End-to-end latency distribution across short / medium / long prompts.

    Sends 3 requests per prompt size (9 total) and reports P50 / P95 latencies.
    Does not assert a hard threshold — prints a summary table for human review.
    Asserts only that P95 across all sizes stays under a generous ceiling.
    """
    prompt_configs = [
        ("short",  32,   30),   # (label, approx_input_tokens, max_output_tokens)
        ("medium", 256,  60),
        ("long",   1024, 80),
    ]
    samples_per_size = 3
    all_latencies: list[float] = []

    print("\n  {:8s}  {:>8s}  {:>8s}  {:>8s}  {:>8s}".format(
        "size", "n_req", "p50(s)", "p95(s)", "avg(s)"
    ))
    print("  " + "-" * 50)

    for label, input_toks, output_toks in prompt_configs:
        prompt = _make_prompt(input_toks)
        latencies: list[float] = []
        for _ in range(samples_per_size):
            t0 = time.perf_counter()
            resp = _chat(prompt, max_tokens=output_toks)
            resp.raise_for_status()
            latencies.append(time.perf_counter() - t0)

        p50 = statistics.median(latencies)
        p95 = statistics.quantiles(latencies, n=20)[-1] if len(latencies) >= 2 else latencies[-1]
        avg = statistics.mean(latencies)
        all_latencies.extend(latencies)

        print(f"  {label:8s}  {samples_per_size:>8d}  {p50:>8.2f}  {p95:>8.2f}  {avg:>8.2f}")

    overall_p95 = statistics.quantiles(all_latencies, n=20)[-1] if len(all_latencies) >= 2 else all_latencies[-1]
    print(f"\n  Overall P95 latency: {overall_p95:.2f}s  (ceiling: {_P95_LATENCY_MAX_S}s)")

    assert overall_p95 <= _P95_LATENCY_MAX_S, (
        f"P95 latency {overall_p95:.2f}s exceeds ceiling {_P95_LATENCY_MAX_S}s"
    )


@_SKIP
def test_concurrent_requests():
    """Four concurrent requests must all succeed within the timeout.

    Fires 4 threads simultaneously. Each sends a short completion.
    Asserts that all threads finish without HTTP errors and within _TIMEOUT seconds.
    """
    n_concurrent = 4
    prompt = "Name one advantage of MoE over dense models in one sentence."
    results: list[tuple[int, float]] = []
    errors: list[str] = []
    lock = threading.Lock()

    def _worker(idx: int) -> None:
        t0 = time.perf_counter()
        try:
            resp = _chat(prompt, max_tokens=40)
            elapsed = time.perf_counter() - t0
            with lock:
                if resp.status_code == 200:
                    toks = _token_count(resp)
                    results.append((toks, elapsed))
                    print(f"  thread {idx}: {toks} tokens in {elapsed:.2f}s", flush=True)
                else:
                    errors.append(f"thread {idx}: HTTP {resp.status_code}")
        except Exception as exc:
            with lock:
                errors.append(f"thread {idx}: {exc}")

    threads = [threading.Thread(target=_worker, args=(i,)) for i in range(n_concurrent)]
    t_wall_start = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=_TIMEOUT)
    wall_elapsed = time.perf_counter() - t_wall_start

    print(f"\n  {len(results)}/{n_concurrent} requests succeeded in {wall_elapsed:.1f}s wall time")
    if errors:
        print(f"  Errors: {errors}")

    assert not errors, f"Concurrent requests had errors: {errors}"
    assert len(results) == n_concurrent, (
        f"Only {len(results)}/{n_concurrent} concurrent requests completed"
    )
    assert wall_elapsed < _TIMEOUT, (
        f"Concurrent requests took {wall_elapsed:.1f}s, exceeded timeout {_TIMEOUT}s"
    )
