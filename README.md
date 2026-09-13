# 5G Edge AI Home Lab

A home-lab simulation of a full **UE → 5G RAN → Core → Edge Kubernetes →
GPU/VLM** data path, built entirely from open-source software. No SDR/RF
hardware is used or required — the radio layer is simulated over IP
(UERANSIM); everything else (5G core signaling, GTP-U tunneling, Kubernetes
GPU scheduling, video ingestion, VLM inference) is real. See
[`docs/what-is-simulated.md`](docs/what-is-simulated.md) for the exact
boundary and [`PROJECT_PLAN.md`](PROJECT_PLAN.md) for the full build brief
this repo implements.

## Status

**Scaffolded, not yet run.** This repository was authored from a cloud build
session with no Docker daemon, no GPU, and no SCTP support — see
[`docs/phase-notes/phase-0.md`](docs/phase-notes/phase-0.md) for the exact
commands that confirmed this. Every phase's infrastructure-as-code is
complete and based on current upstream documentation, but none of it has
been executed or DoD-verified yet. Each `docs/phase-notes/phase-N.md` has an
unchecked DoD checklist — that's the real task list for whoever runs this on
the actual home-lab host (see Section 6 of `PROJECT_PLAN.md` for the target
hardware/OS).

## Architecture

```
[ffmpeg test video]
        |
        v
   uesimtun1 (UERANSIM UE, simulated radio, 'edge' DNN)
        |  (GTP-U tunnel, real encapsulation)
        v
   UERANSIM gNB  <---- NGAP/N2 ---->  Open5GS AMF
        |
        v  (N3, GTP-U)
   Open5GS UPF  ---- local breakout (N6, un-NAT'd) ---->  K3s edge cluster
                                                                |
                                                    mediamtx (RTSP gateway)
                                                                |
                                                    edge-ingest (GPU: YOLOv8n)
                                                                |
                                                    vlm (GPU: Qwen2-VL-7B / vLLM)
                                                                |
                                              Prometheus + DCGM + Grafana
```

Full diagram and addressing table: [`docs/architecture.md`](docs/architecture.md).

## Repository layout

| Path | Phase(s) | What it is |
|---|---|---|
| `core/` | 1 | Open5GS 5G core (Docker Compose, one container per NF) |
| `ran/` | 2 | UERANSIM gNB + UE |
| `edge/` | 3, 4, 5, 6 | Local-breakout routing, K3s + GPU Operator, ingestion + VLM manifests |
| `monitoring/` | 8 | Prometheus, DCGM exporter, Grafana |
| `scripts/` | 1, 2, 5, 7, 9 | Subscriber provisioning, PDU-session check, test video, benchmark |
| `docs/` | all | Architecture, what's simulated, per-phase notes with DoD checklists |

## Quickstart (run on the real host, not this build session)

```bash
cp .env.example .env   # edit if you want different addressing/subnets

# Phase 1: 5G core
cd core && docker compose --env-file ../.env up -d && cd ..
./scripts/provision-subscriber.sh

# Phase 2: RAN/UE
cd ran && docker compose --env-file ../.env up -d && cd ..
./scripts/verify-pdu-session.sh

# Phase 3: local breakout routing (host-side)
./edge/setup-local-breakout-route.sh

# Phase 4: K3s + GPU
./edge/k3s-install.sh
./edge/install-gpu-operator.sh

# Phase 5/6: ingestion + VLM
docker build -t edge-ingest:local edge/ingest
docker save edge-ingest:local | sudo k3s ctr images import -
kubectl apply -f edge/manifests/gateway.yaml -f edge/manifests/ingest-deployment.yaml
sudo mkdir -p /opt/edge-lab/hf-cache
kubectl apply -f edge/manifests/vlm-deployment.yaml

# Phase 7: end-to-end
./scripts/stream-test-video.sh

# Phase 8: observability
./monitoring/deploy.sh

# Phase 9: benchmark
python3 -m venv .venv && . .venv/bin/activate && pip install -r scripts/requirements.txt
python3 scripts/benchmark.py --vlm-url http://<node-ip>:<vlm-port>/v1/chat/completions
```

Each step's real prerequisites, DoD command, and known risks are in the
matching `docs/phase-notes/phase-N.md` — read the one for the phase you're
on before troubleshooting from scratch.

## Non-goals

No real RF/SDR transmission, no multi-cell handover, no AI-RAN GPU sharing
with a real baseband workload, and no security hardening beyond keeping
secrets out of git. See PROJECT_PLAN.md Section 8 for the full list.

## License

MIT — see [`LICENSE`](LICENSE).
