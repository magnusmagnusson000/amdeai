#!/usr/bin/env python3
"""Compare a benchmark JSON run against gfx1151 reference baselines."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def _row(label: str, metric: str, ref: str, new: str) -> str:
    return f"| {label} | {metric} | {ref} | {new} |"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("result_json", help="Output from bench-vllm-endpoint.py --json-out")
    parser.add_argument(
        "--baseline",
        default=str(Path(__file__).resolve().parents[1] / "tests/perf/baselines/gfx1151-r9700.json"),
    )
    parser.add_argument("--label", default="DiffusionGemma 26B")
    args = parser.parse_args()

    result = _load_json(Path(args.result_json))
    baseline = _load_json(Path(args.baseline))
    models = baseline.get("models", {})

    print(f"\n## {args.label} vs reference models ({baseline.get('platform', 'gfx1151')})\n")
    print("| Model | Metric | Reference | This run |")
    print("|-------|--------|-----------|----------|")

    ttft = result.get("ttft_s")
    tps = result.get("throughput_tok_s")
    p95 = result.get("latency_p95_s")

    if ttft is not None:
        ref27 = models.get("qwen3-6-27b-no-mtp", {})
        refmoe = models.get("qwen3-6-35b-moe", {})
        print(_row(args.label, "TTFT (s)", "—", f"{ttft:.2f}"))
        if ref27.get("ttft_median_s") is not None:
            print(_row("Qwen3.6-27B (no MTP)", "TTFT median (s)", f"{ref27['ttft_median_s']:.2f}", "—"))
        if refmoe.get("ttft_threshold_max_s") is not None:
            print(
                _row(
                    "Qwen3.6-35B MoE",
                    "TTFT threshold max (s)",
                    f"{refmoe['ttft_threshold_max_s']:.1f}",
                    f"{ttft:.2f} {'OK' if ttft <= refmoe['ttft_threshold_max_s'] else 'OVER'}",
                )
            )

    if tps is not None:
        ref27 = models.get("qwen3-6-27b-no-mtp", {})
        refmtp = models.get("qwen3-6-27b-mtp", {})
        refmoe = models.get("qwen3-6-35b-moe", {})
        print(_row(args.label, "Throughput (tok/s)", "—", f"{tps:.2f}"))
        if ref27.get("tps_median") is not None:
            print(_row("Qwen3.6-27B (no MTP)", "TPS median", f"{ref27['tps_median']:.2f}", "—"))
        if refmtp.get("tps_median") is not None:
            print(_row("Qwen3.6-27B (MTP)", "TPS median", f"{refmtp['tps_median']:.2f}", "—"))
        if refmoe.get("throughput_min_tok_s") is not None:
            print(
                _row(
                    "Qwen3.6-35B MoE",
                    "Throughput min (tok/s)",
                    f">= {refmoe['throughput_min_tok_s']:.1f}",
                    f"{tps:.2f} {'OK' if tps >= refmoe['throughput_min_tok_s'] else 'UNDER'}",
                )
            )

    if p95 is not None:
        refmoe = models.get("qwen3-6-35b-moe", {})
        print(_row(args.label, "Latency P95 (s)", "—", f"{p95:.2f}"))
        if refmoe.get("p95_latency_ceiling_s") is not None:
            print(
                _row(
                    "Qwen3.6-35B MoE",
                    "P95 ceiling (s)",
                    f"{refmoe['p95_latency_ceiling_s']:.0f}",
                    f"{p95:.2f} {'OK' if p95 <= refmoe['p95_latency_ceiling_s'] else 'OVER'}",
                )
            )

    conc = result.get("concurrent_ok", 0)
    conc_total = result.get("concurrent_total", 0)
    print(_row(args.label, "Concurrent OK", "4/4", f"{conc}/{conc_total}"))

    by_size = result.get("latency_by_size") or {}
    if by_size:
        print("\n### Latency by prompt size (this run)\n")
        print("| Size | P50 (s) | P95 (s) | Avg (s) |")
        print("|------|---------|---------|---------|")
        for label, stats in by_size.items():
            print(
                f"| {label} | {stats['p50_s']:.2f} | {stats['p95_s']:.2f} | {stats['avg_s']:.2f} |"
            )

    if result.get("errors"):
        print(f"\nErrors during run: {result['errors']}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
