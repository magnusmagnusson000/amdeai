"""Shared vLLM OpenAI-compatible endpoint benchmarks for gfx1151 AIM models."""
from __future__ import annotations

import json
import statistics
import threading
import time
from dataclasses import asdict, dataclass, field
from typing import Any

import httpx

# Prompts aligned with tests/perf/test_qwen_moe_perf.py (Qwen gfx1151 perf suite).
PROMPT_TTFT = "Reply with exactly: ready"
PROMPT_THROUGHPUT = "Write a short technical description of mixture-of-experts architecture."
PROMPT_CONCURRENT = "Name one advantage of MoE over dense models in one sentence."
PROMPT_WARMUP = PROMPT_THROUGHPUT
LATENCY_PROMPT_CONFIGS = [
    ("short", 32, 30),
    ("medium", 256, 60),
    ("long", 1024, 80),
]


@dataclass
class BenchConfig:
    endpoint: str
    model: str
    timeout: int = 300
    chat_template_kwargs: dict[str, Any] = field(default_factory=dict)


@dataclass
class BenchResult:
    model: str
    endpoint: str
    warmup_elapsed_s: float = 0.0
    warmup_tokens: int = 0
    ttft_s: float | None = None
    ttft_runs_s: list[float] = field(default_factory=list)
    ttft_median_s: float | None = None
    ttft_mean_s: float | None = None
    throughput_tok_s: float | None = None
    throughput_tokens: int = 0
    throughput_elapsed_s: float = 0.0
    latency_p50_s: float | None = None
    latency_p95_s: float | None = None
    latency_by_size: dict[str, dict[str, float]] = field(default_factory=dict)
    concurrent_ok: int = 0
    concurrent_total: int = 0
    concurrent_wall_s: float = 0.0
    errors: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _chat(cfg: BenchConfig, prompt: str, max_tokens: int = 50) -> httpx.Response:
    payload: dict[str, Any] = {
        "model": cfg.model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
    }
    if cfg.chat_template_kwargs:
        payload["chat_template_kwargs"] = cfg.chat_template_kwargs
    return httpx.post(
        f"{cfg.endpoint.rstrip('/')}/v1/chat/completions",
        json=payload,
        timeout=cfg.timeout,
    )


def _stream_chat(cfg: BenchConfig, prompt: str, max_tokens: int = 80):
    payload: dict[str, Any] = {
        "model": cfg.model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
    }
    if cfg.chat_template_kwargs:
        payload["chat_template_kwargs"] = cfg.chat_template_kwargs
    url = f"{cfg.endpoint.rstrip('/')}/v1/chat/completions"
    with httpx.stream("POST", url, json=payload, timeout=cfg.timeout) as resp:
        resp.raise_for_status()
        for line in resp.iter_lines():
            if line.startswith("data: ") and line != "data: [DONE]":
                yield line[len("data: ") :]


def _token_count(response: httpx.Response) -> int:
    try:
        return int(response.json()["usage"]["completion_tokens"])
    except (KeyError, json.JSONDecodeError, TypeError, ValueError):
        return 0


def _make_prompt(approx_tokens: int) -> str:
    word = "silicon "
    return (word * (approx_tokens // 2)).strip() + " — summarise in one sentence."


def measure_ttft(cfg: BenchConfig, prompt: str = PROMPT_TTFT, max_tokens: int = 20) -> float:
    t_start = time.perf_counter()
    first_token_time: float | None = None
    for _chunk in _stream_chat(cfg, prompt, max_tokens=max_tokens):
        if first_token_time is None:
            first_token_time = time.perf_counter() - t_start
    if first_token_time is None:
        raise RuntimeError("No streaming tokens received")
    return first_token_time


def measure_throughput(
    cfg: BenchConfig,
    n_requests: int = 5,
    tokens_per_request: int = 50,
    prompt: str = PROMPT_THROUGHPUT,
) -> tuple[float, int, float]:
    t_start = time.perf_counter()
    total_tokens = 0
    for _ in range(n_requests):
        resp = _chat(cfg, prompt, max_tokens=tokens_per_request)
        resp.raise_for_status()
        total_tokens += _token_count(resp)
    elapsed = time.perf_counter() - t_start
    toks_per_sec = total_tokens / elapsed if elapsed > 0 else 0.0
    return toks_per_sec, total_tokens, elapsed


def measure_latency_distribution(cfg: BenchConfig) -> tuple[dict[str, dict[str, float]], float, float]:
    prompt_configs = LATENCY_PROMPT_CONFIGS
    samples_per_size = 3
    all_latencies: list[float] = []
    by_size: dict[str, dict[str, float]] = {}

    for label, input_toks, output_toks in prompt_configs:
        prompt = _make_prompt(input_toks)
        latencies: list[float] = []
        for _ in range(samples_per_size):
            t0 = time.perf_counter()
            resp = _chat(cfg, prompt, max_tokens=output_toks)
            resp.raise_for_status()
            latencies.append(time.perf_counter() - t0)
        p50 = statistics.median(latencies)
        p95 = statistics.quantiles(latencies, n=20)[-1] if len(latencies) >= 2 else latencies[-1]
        avg = statistics.mean(latencies)
        by_size[label] = {"p50_s": p50, "p95_s": p95, "avg_s": avg}
        all_latencies.extend(latencies)

    overall_p95 = (
        statistics.quantiles(all_latencies, n=20)[-1] if len(all_latencies) >= 2 else all_latencies[-1]
    )
    overall_p50 = statistics.median(all_latencies)
    return by_size, overall_p50, overall_p95


def measure_concurrent(cfg: BenchConfig, n_concurrent: int = 4, max_tokens: int = 40) -> tuple[int, float, list[str]]:
    prompt = PROMPT_CONCURRENT
    results: list[tuple[int, float]] = []
    errors: list[str] = []
    lock = threading.Lock()

    def _worker(idx: int) -> None:
        t0 = time.perf_counter()
        try:
            resp = _chat(cfg, prompt, max_tokens=max_tokens)
            elapsed = time.perf_counter() - t0
            with lock:
                if resp.status_code == 200:
                    results.append((_token_count(resp), elapsed))
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
        t.join(timeout=cfg.timeout)
    wall_elapsed = time.perf_counter() - t_wall_start
    return len(results), wall_elapsed, errors


def run_warmup(cfg: BenchConfig, max_tokens: int = 50) -> tuple[float, int]:
    """Single completion to JIT-compile kernels / warm caches (discarded from scored metrics)."""
    t0 = time.perf_counter()
    resp = _chat(cfg, PROMPT_WARMUP, max_tokens=max_tokens)
    resp.raise_for_status()
    elapsed = time.perf_counter() - t0
    return elapsed, _token_count(resp)


def measure_ttft_multi(cfg: BenchConfig, n_runs: int = 3) -> list[float]:
    return [measure_ttft(cfg) for _ in range(n_runs)]


def run_extended_benchmark(cfg: BenchConfig, ttft_runs: int = 3) -> BenchResult:
    """Warmup + full Qwen-aligned suite with multi-run TTFT."""
    result = BenchResult(model=cfg.model, endpoint=cfg.endpoint)

    try:
        elapsed, tokens = run_warmup(cfg)
        result.warmup_elapsed_s = elapsed
        result.warmup_tokens = tokens
    except Exception as exc:
        result.errors.append(f"warmup: {exc}")

    try:
        ttft_runs_list = measure_ttft_multi(cfg, n_runs=ttft_runs)
        result.ttft_runs_s = ttft_runs_list
        result.ttft_median_s = statistics.median(ttft_runs_list)
        result.ttft_mean_s = statistics.mean(ttft_runs_list)
        result.ttft_s = result.ttft_median_s
    except Exception as exc:
        result.errors.append(f"ttft: {exc}")

    try:
        tps, tokens, elapsed = measure_throughput(cfg)
        result.throughput_tok_s = tps
        result.throughput_tokens = tokens
        result.throughput_elapsed_s = elapsed
    except Exception as exc:
        result.errors.append(f"throughput: {exc}")

    try:
        by_size, p50, p95 = measure_latency_distribution(cfg)
        result.latency_by_size = by_size
        result.latency_p50_s = p50
        result.latency_p95_s = p95
    except Exception as exc:
        result.errors.append(f"latency: {exc}")

    try:
        ok, wall, errors = measure_concurrent(cfg)
        result.concurrent_ok = ok
        result.concurrent_total = 4
        result.concurrent_wall_s = wall
        result.errors.extend(errors)
    except Exception as exc:
        result.errors.append(f"concurrent: {exc}")

    return result


def run_full_benchmark(cfg: BenchConfig) -> BenchResult:
    result = BenchResult(model=cfg.model, endpoint=cfg.endpoint)
    try:
        result.ttft_s = measure_ttft(cfg)
    except Exception as exc:
        result.errors.append(f"ttft: {exc}")

    try:
        tps, tokens, elapsed = measure_throughput(cfg)
        result.throughput_tok_s = tps
        result.throughput_tokens = tokens
        result.throughput_elapsed_s = elapsed
    except Exception as exc:
        result.errors.append(f"throughput: {exc}")

    try:
        by_size, p50, p95 = measure_latency_distribution(cfg)
        result.latency_by_size = by_size
        result.latency_p50_s = p50
        result.latency_p95_s = p95
    except Exception as exc:
        result.errors.append(f"latency: {exc}")

    try:
        ok, wall, errors = measure_concurrent(cfg)
        result.concurrent_ok = ok
        result.concurrent_total = 4
        result.concurrent_wall_s = wall
        result.errors.extend(errors)
    except Exception as exc:
        result.errors.append(f"concurrent: {exc}")

    return result
