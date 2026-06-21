#!/usr/bin/env python3
"""Run gfx1151 vLLM endpoint benchmark and emit JSON + human summary."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests" / "perf"))

from bench_common import BenchConfig, run_full_benchmark  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark vLLM /v1 chat endpoint")
    parser.add_argument("endpoint", help="Base URL (no trailing slash)")
    parser.add_argument("model", help="Model ID for /v1/chat/completions")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--no-think", action="store_true", help="Pass enable_thinking=false (Qwen)")
    parser.add_argument("--json-out", help="Write results JSON to path")
    args = parser.parse_args()

    kwargs = {"enable_thinking": False} if args.no_think else {}
    cfg = BenchConfig(
        endpoint=args.endpoint.rstrip("/"),
        model=args.model,
        timeout=args.timeout,
        chat_template_kwargs=kwargs,
    )
    result = run_full_benchmark(cfg)
    payload = result.to_dict()

    print("\n=== Benchmark summary ===")
    print(f"Model:     {cfg.model}")
    print(f"Endpoint:  {cfg.endpoint}")
    if result.ttft_s is not None:
        print(f"TTFT:      {result.ttft_s:.2f} s")
    if result.throughput_tok_s is not None:
        print(
            f"Throughput: {result.throughput_tok_s:.2f} tok/s "
            f"({result.throughput_tokens} tokens in {result.throughput_elapsed_s:.1f} s)"
        )
    if result.latency_by_size:
        print("\nLatency by prompt size:")
        print(f"  {'size':8s}  {'p50(s)':>8s}  {'p95(s)':>8s}  {'avg(s)':>8s}")
        for label, stats in result.latency_by_size.items():
            print(
                f"  {label:8s}  {stats['p50_s']:>8.2f}  {stats['p95_s']:>8.2f}  {stats['avg_s']:>8.2f}"
            )
        print(f"\n  Overall P50: {result.latency_p50_s:.2f} s  P95: {result.latency_p95_s:.2f} s")
    print(
        f"\nConcurrent: {result.concurrent_ok}/{result.concurrent_total} OK "
        f"in {result.concurrent_wall_s:.1f} s wall time"
    )
    if result.errors:
        print(f"Errors: {result.errors}")

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(payload, indent=2) + "\n")
        print(f"\nWrote {args.json_out}")

    return 1 if result.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
