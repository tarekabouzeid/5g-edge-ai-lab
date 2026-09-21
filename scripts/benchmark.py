#!/usr/bin/env python3
"""
Phase 9 benchmark harness.

Measures:
  1. Single-stream frame-in -> VLM-result-out latency (calls the VLM service
     directly with a synthetic frame, the same way edge/ingest/app.py does).
  2. Concurrent-stream ramp: increases the number of simultaneous VLM
     requests until latency degrades sharply or GPU utilization plateaus,
     to find this hardware's saturation point.

Run on the real host, with the edge cluster (Phase 4-6) up:
    python3 scripts/benchmark.py --vlm-url http://<node-ip>:<vlm-nodeport>/v1/chat/completions

Writes docs/benchmark-results.md with real numbers, plus a raw JSON dump.
This script has not been executed against a live VLM service from the build
session this repo was scaffolded from (see docs/phase-notes/phase-0.md /
phase-9.md) — run it for real and let it fill in the results doc.
"""
import argparse
import base64
import json
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import cv2
import numpy as np
import requests


def synthetic_frame_b64() -> str:
    frame = np.random.randint(0, 255, (720, 1280, 3), dtype=np.uint8)
    ok, buf = cv2.imencode(".jpg", frame)
    assert ok
    return base64.b64encode(buf.tobytes()).decode("ascii")


def vlm_request(vlm_url: str, model: str, frame_b64: str) -> float:
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Describe this frame in one sentence."},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{frame_b64}"}},
                ],
            }
        ],
        "max_tokens": 64,
    }
    start = time.time()
    resp = requests.post(vlm_url, json=payload, timeout=60)
    resp.raise_for_status()
    return time.time() - start


def gpu_snapshot() -> dict:
    """Best-effort nvidia-smi read; returns {} if unavailable (e.g. this is
    being run from a machine without the driver, matching this repo's own
    build-session limitation — see docs/phase-notes/phase-0.md)."""
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total",
             "--format=csv,noheader,nounits"],
            text=True, timeout=5,
        )
        util, mem_used, mem_total = [x.strip() for x in out.strip().split(",")]
        return {"gpu_util_pct": int(util), "mem_used_mib": int(mem_used), "mem_total_mib": int(mem_total)}
    except Exception:
        return {}


def run_single_stream(vlm_url: str, model: str, n: int) -> list[float]:
    frame_b64 = synthetic_frame_b64()
    latencies = []
    for _ in range(n):
        latencies.append(vlm_request(vlm_url, model, frame_b64))
    return latencies


def run_concurrency_ramp(vlm_url: str, model: str, max_concurrency: int, requests_per_level: int) -> list[dict]:
    frame_b64 = synthetic_frame_b64()
    results = []
    for concurrency in range(1, max_concurrency + 1):
        latencies = []
        before = gpu_snapshot()
        start = time.time()
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            futures = [pool.submit(vlm_request, vlm_url, model, frame_b64)
                       for _ in range(requests_per_level * concurrency)]
            for f in futures:
                latencies.append(f.result())
        wall = time.time() - start
        after = gpu_snapshot()
        total_requests = requests_per_level * concurrency
        results.append({
            "concurrency": concurrency,
            "requests": total_requests,
            "wall_seconds": wall,
            "throughput_req_per_sec": total_requests / wall,
            "latency_p50": sorted(latencies)[len(latencies) // 2],
            "latency_p95": sorted(latencies)[int(len(latencies) * 0.95) - 1],
            "gpu_before": before,
            "gpu_after": after,
        })
        print(f"concurrency={concurrency}: p50={results[-1]['latency_p50']:.2f}s "
              f"p95={results[-1]['latency_p95']:.2f}s "
              f"throughput={results[-1]['throughput_req_per_sec']:.2f} req/s "
              f"gpu_util={after.get('gpu_util_pct')}%")
    return results


def write_report(single: list[float], ramp: list[dict], out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    raw = {"single_stream_latencies": single, "concurrency_ramp": ramp,
           "generated_at": datetime.now(timezone.utc).isoformat()}
    (out_dir / "benchmark-raw.json").write_text(json.dumps(raw, indent=2))

    single_sorted = sorted(single)
    p50 = single_sorted[len(single_sorted) // 2]
    p95 = single_sorted[int(len(single_sorted) * 0.95) - 1]

    saturation = None
    for i in range(1, len(ramp)):
        if ramp[i]["throughput_req_per_sec"] < ramp[i - 1]["throughput_req_per_sec"] * 1.05:
            saturation = ramp[i]
            break

    lines = [
        "# Benchmark Results",
        "",
        f"Generated: {raw['generated_at']}",
        "",
        "## Single-stream latency (frame in -> VLM caption out)",
        "",
        f"- p50: {p50:.2f}s",
        f"- p95: {p95:.2f}s",
        f"- n: {len(single)}",
        "",
        "## Concurrency ramp",
        "",
        "| Concurrency | Requests | Throughput (req/s) | p50 latency (s) | p95 latency (s) | GPU util % (after) | VRAM used (MiB) |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in ramp:
        lines.append(
            f"| {r['concurrency']} | {r['requests']} | {r['throughput_req_per_sec']:.2f} "
            f"| {r['latency_p50']:.2f} | {r['latency_p95']:.2f} "
            f"| {r['gpu_after'].get('gpu_util_pct', 'n/a')} | {r['gpu_after'].get('mem_used_mib', 'n/a')} |"
        )
    lines.append("")
    if saturation:
        lines.append(
            f"**Saturation point:** concurrency {saturation['concurrency']} — throughput stopped "
            f"improving materially beyond this point (GPU util {saturation['gpu_after'].get('gpu_util_pct', 'n/a')}%, "
            f"VRAM {saturation['gpu_after'].get('mem_used_mib', 'n/a')} MiB)."
        )
    else:
        lines.append("**Saturation point:** not reached within the tested concurrency range — "
                      "re-run with a higher --max-concurrency.")
    (out_dir.parent / "benchmark-results.md").write_text("\n".join(lines) + "\n")
    print(f"\nWrote {out_dir.parent / 'benchmark-results.md'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vlm-url", required=True, help="e.g. http://<node-ip>:<nodeport>/v1/chat/completions")
    ap.add_argument("--model", default="Qwen/Qwen2-VL-2B-Instruct")
    ap.add_argument("--single-stream-requests", type=int, default=20)
    ap.add_argument("--max-concurrency", type=int, default=8)
    ap.add_argument("--requests-per-level", type=int, default=5)
    ap.add_argument("--out-dir", default="docs/benchmark-results")
    args = ap.parse_args()

    print("=== Single-stream latency ===")
    single = run_single_stream(args.vlm_url, args.model, args.single_stream_requests)

    print("\n=== Concurrency ramp ===")
    ramp = run_concurrency_ramp(args.vlm_url, args.model, args.max_concurrency, args.requests_per_level)

    write_report(single, ramp, Path(args.out_dir))


if __name__ == "__main__":
    main()
