#!/usr/bin/env python3
"""Extended vLLM benchmark: warmup + Qwen-aligned prompts + multi-run TTFT."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "perf"))

from bench_common import (  # noqa: E402
    LATENCY_PROMPT_CONFIGS,
    PROMPT_CONCURRENT,
    PROMPT_THROUGHPUT,
    PROMPT_TTFT,
    PROMPT_WARMUP,
    BenchConfig,
    run_extended_benchmark,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Extended vLLM benchmark (warmup + Qwen prompts)")
    parser.add_argument("endpoint", help="Base URL (no trailing slash)")
    parser.add_argument("model", help="Model ID for /v1/chat/completions")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--ttft-runs", type=int, default=3)
    parser.add_argument("--json-out", help="Write results JSON to path")
    args = parser.parse_args()

    cfg = BenchConfig(endpoint=args.endpoint.rstrip("/"), model=args.model, timeout=args.timeout)
    result = run_extended_benchmark(cfg, ttft_runs=args.ttft_runs)
    payload = result.to_dict()

    print("\n=== Extended benchmark (Qwen-aligned prompts) ===")
    print(f"Model:     {cfg.model}")
    print(f"Endpoint:  {cfg.endpoint}")
    print("\nPrompts:")
    print(f"  warmup/throughput: {PROMPT_WARMUP[:60]}...")
    print(f"  ttft:              {PROMPT_TTFT}")
    print(f"  concurrent:        {PROMPT_CONCURRENT[:60]}...")
    print(f"  latency sizes:     {[c[0] for c in LATENCY_PROMPT_CONFIGS]}")

    if result.warmup_elapsed_s:
        print(f"\nWarmup:    {result.warmup_tokens} tokens in {result.warmup_elapsed_s:.2f} s (discarded)")

    if result.ttft_runs_s:
        runs = ", ".join(f"{t:.2f}" for t in result.ttft_runs_s)
        print(f"TTFT:      median {result.ttft_median_s:.2f} s  mean {result.ttft_mean_s:.2f} s  runs [{runs}]")

    if result.throughput_tok_s is not None:
        print(
            f"Throughput (short 5x50): {result.throughput_tok_s:.2f} tok/s "
            f"({result.throughput_tokens} tokens in {result.throughput_elapsed_s:.1f} s)"
        )

    if result.throughput_long_tok_s is not None:
        print(
            f"Throughput (long {result.throughput_long_max_tokens} tok): "
            f"{result.throughput_long_tok_s:.2f} tok/s aggregate, "
            f"{result.throughput_long_per_request_tok_s:.2f} tok/s per-request "
            f"({result.throughput_long_tokens} tokens in {result.throughput_long_elapsed_s:.1f} s)"
        )

    if result.latency_by_size:
        print("\nLatency by prompt size:")
        print(f"  {'size':8s}  {'p50(s)':>8s}  {'p95(s)':>8s}  {'avg(s)':>8s}")
        for label, stats in result.latency_by_size.items():
            print(
                f"  {label:8s}  {stats['p50_s']:>8.2f}  {stats['p95_s']:>8.2f}  {stats['avg_s']:>8.2f}"
            )
        if result.latency_p95_s is not None:
            print(f"  Overall P50: {result.latency_p50_s:.2f} s  P95: {result.latency_p95_s:.2f} s")

    print(f"\nConcurrent: {result.concurrent_ok}/{result.concurrent_total} OK in {result.concurrent_wall_s:.1f} s")

    if result.errors:
        print(f"\nErrors: {result.errors}")

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(payload, indent=2) + "\n")
        print(f"\nWrote {args.json_out}")

    return 1 if result.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
