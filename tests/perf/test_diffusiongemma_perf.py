"""Performance tests for google/diffusiongemma-26B-A4B-it on gfx1151 via vLLM.

Same metrics as tests/perf/test_qwen_moe_perf.py:
  - TTFT (streaming)
  - Sustained throughput (5 x 50 tokens)
  - Latency distribution (short / medium / long)
  - Concurrent requests (4 threads)

Usage:
    PERF_ENDPOINT=https://<node>/<path> \\
    PERF_MODEL=google/diffusiongemma-26B-A4B-it \\
        pytest tests/perf/test_diffusiongemma_perf.py -v -s
"""
from __future__ import annotations

import os

import httpx
import pytest

from tests.perf.bench_common import BenchConfig, measure_concurrent, measure_latency_distribution, measure_throughput, measure_ttft

_ENDPOINT = os.environ.get("PERF_ENDPOINT", "").rstrip("/")
_MODEL = os.environ.get("PERF_MODEL", "google/diffusiongemma-26B-A4B-it")
_TIMEOUT = int(os.environ.get("PERF_TIMEOUT", "300"))

_SKIP = pytest.mark.skipif(
    not _ENDPOINT,
    reason="Set PERF_ENDPOINT=http(s)://<host>/<path> to run performance tests",
)

_TTFT_MAX_S = float(os.environ.get("PERF_DG_TTFT_MAX_S", "30.0"))
_THROUGHPUT_MIN_TOKS = float(os.environ.get("PERF_DG_THROUGHPUT_MIN", "1.0"))
_P95_LATENCY_MAX_S = float(os.environ.get("PERF_DG_P95_MAX_S", "180.0"))


def _cfg() -> BenchConfig:
    return BenchConfig(endpoint=_ENDPOINT, model=_MODEL, timeout=_TIMEOUT)


@_SKIP
def test_health_check():
    resp = httpx.get(f"{_ENDPOINT}/health", timeout=30)
    assert resp.status_code in (200, 404)


@_SKIP
def test_models_endpoint():
    resp = httpx.get(f"{_ENDPOINT}/v1/models", timeout=30)
    resp.raise_for_status()
    model_ids = [m["id"] for m in resp.json().get("data", [])]
    assert any(_MODEL in mid or "diffusiongemma" in mid.lower() for mid in model_ids), (
        f"Model {_MODEL!r} not found. Found: {model_ids}"
    )


@_SKIP
def test_ttft_short_prompt():
    ttft = measure_ttft(_cfg(), prompt="Reply with exactly: ready", max_tokens=20)
    print(f"\n  TTFT: {ttft:.2f}s  (threshold: {_TTFT_MAX_S}s)")
    assert ttft <= _TTFT_MAX_S, f"TTFT {ttft:.2f}s exceeds {_TTFT_MAX_S}s"


@_SKIP
def test_throughput_sustained():
    tps, tokens, elapsed = measure_throughput(
        _cfg(),
        prompt="Explain discrete diffusion language models in two sentences.",
    )
    print(f"\n  Throughput: {tps:.2f} tok/s ({tokens} tokens in {elapsed:.1f}s)")
    assert tps >= _THROUGHPUT_MIN_TOKS, f"Throughput {tps:.2f} tok/s below {_THROUGHPUT_MIN_TOKS}"


@_SKIP
def test_latency_distribution():
    by_size, _p50, p95 = measure_latency_distribution(_cfg())
    print("\n  {:8s}  {:>8s}  {:>8s}  {:>8s}".format("size", "p50(s)", "p95(s)", "avg(s)"))
    print("  " + "-" * 50)
    for label, stats in by_size.items():
        print(f"  {label:8s}  {stats['p50_s']:>8.2f}  {stats['p95_s']:>8.2f}  {stats['avg_s']:>8.2f}")
    print(f"\n  Overall P95: {p95:.2f}s  (ceiling: {_P95_LATENCY_MAX_S}s)")
    assert p95 <= _P95_LATENCY_MAX_S


@_SKIP
def test_concurrent_requests():
    ok, wall, errors = measure_concurrent(_cfg())
    print(f"\n  {ok}/4 succeeded in {wall:.1f}s")
    assert not errors, errors
    assert ok == 4
    assert wall < _TIMEOUT
