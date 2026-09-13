# 5G Edge AI Home Lab

[![CI](https://github.com/tarekabouzeid/Edge-compute-Open5GS-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/tarekabouzeid/Edge-compute-Open5GS-lab/actions/workflows/ci.yml)

A home-lab simulation of a full **UE → 5G RAN → Core → Edge Kubernetes →
GPU/VLM** data path, built entirely from open-source software. No SDR/RF
hardware is used or required — the radio layer is simulated over IP
(UERANSIM); everything else (5G core signaling, GTP-U tunneling, Kubernetes
GPU scheduling, video ingestion, VLM inference) is real. See
[`docs/what-is-simulated.md`](docs/what-is-simulated.md) for the exact
boundary and [`PROJECT_PLAN.md`](PROJECT_PLAN.md) for the full build brief.

## Status

**Scaffolded, not yet run on real hardware.** This repo was authored from a
cloud build session with no Docker daemon, no GPU, and no SCTP support —
see [`docs/phase-notes/phase-0.md`](docs/phase-notes/phase-0.md). CI (badge
above) validates every config/manifest/script and actually brings up the
Open5GS core on every push; the GPU/RAN/edge path (including building and
running the `edge/ingest` image) needs a real GPU host and is validated
there instead, per each phase's `docs/phase-notes/phase-N.md`.

## Requirements

Real host: Ubuntu 22.04/24.04, Docker + Compose v2, NVIDIA driver + Container
Toolkit, `helm`, `kubectl`, sudo. Local dev/test only (no GPU): Docker + `kind`.
All image/package versions are pinned to latest-as-of-2026-09-13 in
`.env.example`; re-check anytime with `./scripts/check-latest-versions.sh`.

## Quickstart — real host (full stack, GPU required)

```bash
cp .env.example .env        # edit EDGE_NODE_IP, GRAFANA_ADMIN_PASSWORD at least
./lab.sh all up             # core -> RAN -> K3s+GPU Operator -> edge apps -> monitoring
./scripts/stream-test-video.sh
python3 scripts/benchmark.py --vlm-url http://<node-ip>:8000/v1/chat/completions
./lab.sh status             # anytime
./lab.sh all down           # non-destructive teardown
```

`lab.sh all up` runs, in order: Open5GS core + subscriber provisioning
(Phase 1) → UERANSIM RAN + PDU session check (Phase 2) → `edge/
setup-local-breakout-route.sh` **(run this manually once — host routing,
Phase 3)** → K3s + GPU Operator (Phase 4) → gateway/ingest/VLM manifests
(Phases 5–6) → Prometheus/DCGM/Grafana (Phase 8). See `docs/phase-notes/
phase-N.md` for each step's real DoD check and known risks — read the one
for whatever fails before troubleshooting from scratch.

Per-layer control: `./lab.sh <core|ran|k3s|edge-apps|monitoring> <up|down>`
— run `./lab.sh` with no args for the full command list.

## Quickstart — local dev/test (no GPU, via KIND)

Validates the K8s manifests and the ingestion pipeline's plumbing only — no
real GPU inference, no VLM, no RAN. See
[`edge/kind/README.md`](edge/kind/README.md) for exact scope.

```bash
cp .env.example .env
./lab.sh kind up
EDGE_NODE_IP=localhost ./scripts/stream-test-video.sh
./lab.sh kind down
```

## CI

`.github/workflows/ci.yml` runs on every push: YAML/JSON/shell/Python/
Dockerfile lint, Kubernetes manifest validation (kubeconform), and a real
Open5GS core bring-up + subscriber provisioning smoke test. Building the
`edge/ingest` image (a multi-GB CUDA/PyTorch base) and the KIND smoke test
built from it are manual-only (`Actions` tab → `Run workflow`) rather than
run on every push — that image needs a real GPU to be a meaningful test
anyway, so it's validated on the actual GPU host instead (see
`docs/phase-notes/phase-5.md`). CI does not (and cannot, on shared runners)
validate real RAN registration, the UPF's TUN device, or GPU inference —
see the workflow file's header comment for the exact scope.

## Repository layout

| Path | Phase(s) | What it is |
|---|---|---|
| `core/` | 1 | Open5GS 5G core (Docker Compose, one container per NF) |
| `ran/` | 2 | UERANSIM gNB + UE |
| `edge/` | 3–6 | Local-breakout routing, K3s+GPU Operator, KIND alternative, ingestion + VLM manifests |
| `monitoring/` | 8 | Prometheus, DCGM exporter, Grafana |
| `scripts/` | 1,2,5,7,9 | Subscriber provisioning, PDU-session check, test video, benchmark, version check |
| `docs/` | all | Architecture, what's simulated, per-phase notes with DoD checklists |
| `lab.sh` | — | Single entrypoint controlling every layer above |

## Non-goals

No real RF/SDR transmission, no multi-cell handover, no AI-RAN GPU sharing
with a real baseband workload, and no security hardening beyond keeping
secrets out of git. See `PROJECT_PLAN.md` Section 8.

## License

MIT — see [`LICENSE`](LICENSE).
