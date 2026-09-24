# Phase 9 — Benchmarking

## Status: Not yet run — everything it needs (Phase 6) is now up; run the commands below

## What was built

- `scripts/benchmark.py`: measures single-stream frame-in→VLM-caption-out
  latency, then ramps concurrent requests (1..N) against the VLM service
  directly, recording throughput, p50/p95 latency, and `nvidia-smi`
  GPU utilization/VRAM at each concurrency level. Writes
  `docs/benchmark-results.md` (a real report, once actually run) plus a raw
  JSON dump under `docs/benchmark-results/`.
- The "saturation point" is picked automatically as the first concurrency
  level where throughput stops improving by more than 5% over the previous
  level — a simple, inspectable heuristic, not a fixed assumption about
  where this particular GPU will actually saturate.

## How to run this for real (on the actual host, after Phase 6)

```bash
pip install -r scripts/requirements.txt
kubectl port-forward svc/vlm 8000:8000 &
python3 scripts/benchmark.py --vlm-url http://localhost:8000/v1/chat/completions \
  --max-concurrency 8 --requests-per-level 5
cat docs/benchmark-results.md
```

## DoD (copy real output here once run on the target host)

- [ ] `docs/benchmark-results.md` contains real single-stream latency
      numbers and a concurrency-ramp table with actual GPU utilization/VRAM
      figures from this hardware — **not** the placeholder text currently in
      this repo (no such file has been generated yet; this phase-note itself
      is the placeholder until the script is run for real)

## Known risks to watch for on first real run

- `--max-concurrency` should be raised past the point where GPU utilization
  first hits ~100% to confirm the saturation heuristic actually found a real
  plateau and not just a network/CPU bottleneck in the benchmark client
  itself — run it from the same host as the cluster to rule out client-side
  network latency skewing the numbers.
- vLLM's own request queuing/batching means throughput may keep improving
  well past what naive intuition expects before it truly saturates — trust
  the measured curve over assumptions.
