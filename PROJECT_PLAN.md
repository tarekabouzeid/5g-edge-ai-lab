# 5G Edge AI Home Lab — Project Plan

> **Original build brief, kept as written.** Where the real build deviated —
> minikube instead of K3s + GPU Operator on the WSL2 host, llama.cpp instead
> of vLLM, detection on CPU so the VLM owns the single GPU, and the lab
> portal added for live demos — the reasons are in `docs/phase-notes/`
> (phase-4, phase-5, phase-6) and the current state in `README.md`.

## 0. Purpose of this document

This is a build brief for an autonomous coding agent (Claude Code) to implement a
home-lab simulation of a full **UE → 5G RAN → Core → Edge Kubernetes → GPU/VLM**
data path, using open-source software only (no SDR/RF hardware required).

The goal is hands-on, working infrastructure — not a tutorial. The agent should
build, test, and validate each phase before moving to the next, and should flag
back to the human operator (not silently work around) any hardware/OS/driver
blocker it cannot resolve on its own.

---

## 1. Background & Motivation

The operator (project owner) is a telecom/AI infrastructure architect evaluating
GPU/VLM co-location at 5G edge sites (cell-site and aggregation-site tiers) for a
real industry pilot. Before working with real telco infrastructure, they want a
home lab that:

1. Demonstrates the full packet path a real deployment would use — UE traffic,
   radio access, 5G core, local breakout, and edge GPU inference — end to end.
2. Provides real, measurable GPU performance numbers (latency, throughput,
   concurrent-stream saturation point) as a sizing reference.
3. Is a safe, legal, interference-free environment: **no real radio transmission
   is used or required**. The RAN/UE layer is fully simulated over IP.

This lab intentionally mirrors (at toy scale) the target production pattern:
UE → gNodeB → local UPF breakout → edge K8s cluster → GPU pods running video
ingestion + VLM/LLM inference, with a control-plane link back to a "central"
tier for model updates and fleet management.

---

## 2. What is real vs. simulated (read this before building)

| Layer | Status in this lab | Notes |
|---|---|---|
| 5G Core (AMF/SMF/UPF/UDM/etc.) | **Real** | Open5GS — production-grade open-source implementation, same protocols as a commercial core |
| PDU session establishment, NAS/NGAP signaling, GTP-U tunneling | **Real** | UERANSIM implements real control-plane procedures against Open5GS |
| Radio/PHY layer (OFDM, antennas, scheduling, HARQ) | **Simulated over UDP** | UERANSIM has no real radio interface — this is the one deliberate gap |
| IP data path (video traffic through the UE's tunnel) | **Real** | Real packets, real TUN interface, real GTP-U encapsulation |
| Edge Kubernetes cluster + GPU scheduling | **Real** | K3s + NVIDIA GPU Operator on real hardware |
| Video ingestion + inference (DeepStream/VLM) | **Real** | Real GPU compute, real model output |
| Multi-site geographic distribution, AI-RAN GPU sharing with baseband | **Out of scope** | Single machine; no real baseband workload exists to share the GPU with |

Do not let the agent (or the operator) mistake this for a full RF-accurate
testbed — it is a **core-network and edge-compute** lab, not a radio lab. This
is intentional and is the correct scope for what's being learned.

---

## 3. Target Architecture

```
[ffmpeg/GStreamer test video]
        |
        v
   uesimtun0 (UERANSIM UE, simulated radio)
        |  (GTP-U tunnel, real encapsulation)
        v
   UERANSIM gNB  <---- NGAP/N2 ---->  Open5GS AMF
        |
        v  (N3, GTP-U)
   Open5GS UPF  ---- local breakout (N6) ---->  Edge network segment
                                                      |
                                                      v
                                    +---------------------------------+
                                    |     K3s "Edge Site" Cluster     |
                                    |                                 |
                                    |  [Ingress/Gateway Pod]          |
                                    |         |                      |
                                    |         v                      |
                                    |  [Pod: DeepStream/GStreamer     |
                                    |   video ingest + light CV]      |
                                    |         |                      |
                                    |         v                      |
                                    |  [Pod: VLM inference service    |
                                    |   e.g. Qwen2-VL-7B via vLLM]    |
                                    |         |                      |
                                    |         v (GPU: any NVIDIA card,|
                                    |   NVIDIA GPU Operator/device    |
                                    |   plugin, shared via requests/  |
                                    |   limits or MPS)                |
                                    +---------------------------------+
                                                      |
                                                      v
                                    [Prometheus + DCGM exporter + Grafana]
                                    [Benchmark scripts: latency/throughput]
```

Stretch goal (Phase 8): split the single K3s cluster into two logical tiers
(cell-site tier: lightweight detection pod; aggregation tier: VLM/LLM pod) using
node labels/taints, to mirror the two-tier real-world design (small GPU at cell
site, bigger GPU at aggregation site).

---

## 4. Component Choices & Rationale

| Component | Choice | Why |
|---|---|---|
| 5G Core | **Open5GS** | Most mature open-source 5G core, active development, Docker-friendly, widely documented alongside UERANSIM |
| RAN/UE simulator | **UERANSIM** | Only open-source 5G-SA gNB+UE implementation; produces a real TUN interface (`uesimtun0`) carrying genuine GTP-U-tunneled IP traffic — no SDR required |
| Container/orchestration | **K3s** | Lightweight Kubernetes distribution, minimal resource footprint, closest open-source analogue to a real far-edge K8s deployment |
| GPU scheduling in K8s | **NVIDIA GPU Operator** (or `k8s-device-plugin` if Operator is too heavy for a single node) | Standard way to expose a GPU to K8s pods; same approach used in production edge K8s clusters |
| Video ingestion | **NVIDIA DeepStream** (fallback: plain GStreamer + OpenCV if DeepStream install proves too fragile on a single consumer GPU) | Matches the real reference architecture (Metropolis/VSS pattern) discussed for the production design |
| VLM serving | **vLLM serving a small open VLM (e.g., Qwen2-VL-7B, quantized if needed)** | Fits comfortably in 16GB VRAM; OpenAI-compatible API is easy to test and benchmark |
| Monitoring | **DCGM Exporter + Prometheus + Grafana** | Standard GPU observability stack; gives real utilization/latency dashboards |
| Traffic generation | **ffmpeg / GStreamer scripts pushing RTSP or file-based video through `uesimtun0`** | Simplest way to generate realistic video load through the simulated UE path |

The agent should default to these choices. If a component proves impractical on
the target hardware (see Section 6), document the blocker and propose the
closest viable substitute rather than silently downgrading scope.

---

## 5. Repository Structure

```
5g-edge-ai-lab/
├── README.md                      # Quickstart + architecture summary
├── PROJECT_PLAN.md                # This document
├── docs/
│   ├── architecture.md            # Detailed diagram + component explanation
│   ├── what-is-simulated.md       # Copy of Section 2 table, expanded
│   └── phase-notes/               # One file per phase: what was done, issues hit
├── core/
│   ├── docker-compose.yml         # Open5GS deployment
│   └── config/                    # AMF/SMF/UPF/UDM/etc. yaml configs
├── ran/
│   ├── gnb-config.yaml            # UERANSIM gNB config
│   └── ue-config.yaml             # UERANSIM UE config
├── edge/
│   ├── k3s-install.sh             # Cluster bootstrap script
│   ├── gpu-operator/              # GPU Operator/device plugin manifests
│   └── manifests/
│       ├── ingest-deployment.yaml
│       ├── vlm-deployment.yaml
│       └── gateway.yaml
├── scripts/
│   ├── stream-test-video.sh       # Pushes video through uesimtun0
│   ├── benchmark.py               # Latency/throughput measurement harness
│   └── verify-pdu-session.sh      # Sanity check: UE registered, tunnel up
├── monitoring/
│   ├── prometheus/
│   └── grafana-dashboards/
├── .env.example
├── .gitignore                     # Exclude secrets, certs, local overrides
└── LICENSE
```

---

## 6. Hardware & OS Prerequisites

- **Host**: machine with an NVIDIA GPU (16GB+ VRAM recommended for the VLM;
  the reference build used an RTX 5070 Ti — any CUDA-capable NVIDIA card the
  GPU Operator supports should work), reasonable CPU/RAM headroom for
  running the core, RAN sim, and K3s concurrently on one box (recommend
  32GB+ system RAM as a comfort margin).
- **OS**: Ubuntu 22.04 or 24.04 LTS — best current support for NVIDIA drivers,
  container toolkit, and the Open5GS/UERANSIM build instructions.
- **NVIDIA driver + CUDA + NVIDIA Container Toolkit** installed and verified
  (`nvidia-smi` working, `docker run --gpus all` working) *before* starting
  Phase 4.
- **Networking**: decide early (Phase 0 task) whether Open5GS, UERANSIM, and K3s
  run as separate processes/containers on Docker bridge networks on one host, or
  in separate VMs for cleaner network isolation. Community tutorials commonly use
  either approach — the agent should pick one, document why, and stay consistent
  rather than mixing approaches mid-build.
- **Root/sudo access** — required for TUN interface creation and SCTP sockets.

---

## 7. Build Phases

Each phase has a clear Definition of Done (DoD). Do not proceed to the next
phase until the current one's DoD is met and verified with a real command/log,
not assumed.

### Phase 0 — Environment Prep
- Install OS packages, Docker, NVIDIA driver/toolkit, verify GPU visible to Docker.
- Decide and document the networking approach (Section 6).
- **DoD**: `nvidia-smi` and `docker run --rm --gpus all nvidia/cuda:12.x-base nvidia-smi` both succeed.

### Phase 1 — 5G Core (Open5GS)
- Deploy Open5GS (Docker Compose or native build) with default AMF/SMF/UPF/UDM/etc.
- Provision a test subscriber in the UDM/HSS database.
- **DoD**: Open5GS services all report healthy/running; subscriber record confirmed in DB.

### Phase 2 — RAN/UE Simulation (UERANSIM)
- Build and configure UERANSIM gNB against the Open5GS AMF (N2).
- Build and configure UERANSIM UE, run initial registration + PDU session establishment.
- **DoD**: `nr-ue` logs show successful registration and PDU session setup; `uesimtun0` interface exists with an assigned IP; `ping` through `uesimtun0` succeeds to an external address.

### Phase 3 — Local Breakout Configuration
- Configure the UPF's DNN/APN so traffic for a specific data network routes to
  the local "edge" network segment instead of (or in addition to) the internet.
- **DoD**: traffic sent through `uesimtun0` to the edge segment's address is confirmed (via `tcpdump`/`tshark` on the UPF's N6 side) to be delivered locally, without leaving the host/lab network.

### Phase 4 — Edge K3s Cluster + GPU
- Install K3s (single node is fine for MVP).
- Install NVIDIA GPU Operator (or device plugin); confirm GPU appears as an allocatable resource.
- **DoD**: `kubectl describe node` shows `nvidia.com/gpu` in allocatable resources; a test pod requesting the GPU runs `nvidia-smi` successfully inside the cluster.

### Phase 5 — Video Ingestion Pipeline
- Deploy a DeepStream (or GStreamer/OpenCV fallback) pod that can ingest an RTSP stream and run a lightweight CV model (e.g., object detection) on GPU.
- Expose it on the edge network segment reachable from Phase 3's breakout path.
- **DoD**: a test RTSP stream pushed from outside the cluster is ingested and produces detection output in pod logs; GPU utilization visibly rises during ingestion (`nvidia-smi dmon`).

### Phase 6 — VLM Inference Service
- Deploy vLLM (or equivalent) serving a small VLM, exposed via an HTTP API within the cluster.
- Wire the ingestion pipeline (Phase 5) to sample frames/clips and call the VLM API.
- **DoD**: a sample video produces sensible VLM-generated captions/descriptions returned via the API.

### Phase 7 — End-to-End Integration
- Run `scripts/stream-test-video.sh`: pushes a real test video from the UE side, through `uesimtun0`, through the local breakout, into the ingestion pod, through to the VLM.
- **DoD**: a single documented command/script demonstrates video going in at the "UE" and a VLM-generated result coming out at the "edge," with no manual intervention.

### Phase 8 — Observability
- Deploy Prometheus + DCGM Exporter + Grafana; build a dashboard showing GPU utilization, memory, and temperature during test runs.
- **DoD**: dashboard visibly reflects load changes when `stream-test-video.sh` runs.

### Phase 9 — Benchmarking
- Build `scripts/benchmark.py`: measures frame-in→result-out latency for a single stream, then ramps concurrent streams until the GPU saturates (utilization plateaus or latency degrades sharply).
- Produce `docs/benchmark-results.md` with the findings (single-stream latency, max concurrent streams, GPU utilization/VRAM at saturation).
- **DoD**: a documented, reproducible benchmark report exists with real numbers from this hardware.

### Phase 10 — Stretch: Two-Tier Simulation
- Using node labels/taints (or a second K3s node/VM if available), split the ingestion pod (cell-site tier) from the VLM pod (aggregation tier), and route between them to mirror the real two-tier design.
- **DoD**: the two tiers run as separately schedulable/observable units, and the data path (ingestion tier → aggregation tier) is unchanged in behavior from Phase 7.

### Phase 11 — Stretch: GPU Multi-Tenancy
- Experiment with running the ingestion pod and VLM pod concurrently on the single GPU using K8s resource requests/limits (and MPS or time-slicing if available on this GPU/driver combination), as a small-scale analogue of Run:ai-style multi-tenant GPU scheduling.
- **DoD**: both workloads run concurrently without one starving the other; resource allocation behavior is documented.

### Phase 12 — Documentation Pass
- Finalize `README.md` and `docs/architecture.md`.
- Write `docs/lessons-learned.md` mapping each simulated component to its real-world production counterpart (e.g., "Open5GS UPF ↔ production UPF/local breakout," "K3s ingestion pod ↔ ARC-Compact cell-site tier," "vLLM VLM pod ↔ Metropolis VSS RT-VLM microservice on RTX PRO 6000").

---

## 8. Explicit Non-Goals

- No real RF/SDR transmission — nothing in this lab should require a radio
  license or shielded environment.
- No attempt to reproduce real handover between multiple physical cells.
- No attempt to reproduce AI-RAN GPU sharing between baseband processing and AI
  workloads — there is no real baseband workload in this lab.
- Not a security-hardened deployment — default/test credentials are acceptable
  for a home lab, but must never be committed to git (see `.gitignore` /
  `.env.example`).

---

## 9. Definition of Done (MVP)

The project is MVP-complete when, from a clean checkout:

1. A single documented setup script (or clearly ordered manual steps) brings up
   Open5GS, UERANSIM, and the K3s edge cluster.
2. `scripts/verify-pdu-session.sh` confirms the simulated UE has a live tunnel.
3. `scripts/stream-test-video.sh` pushes a real video through that tunnel and a
   VLM-generated result is produced at the edge.
4. GPU utilization is visibly and correctly driven by that traffic (Grafana
   dashboard or `nvidia-smi dmon` output attached as evidence).
5. `docs/benchmark-results.md` contains real latency/throughput numbers for this
   hardware.

---

## 10. Instructions for the Building Agent (Claude Code)

- Work phase by phase in the order above. Do not skip ahead.
- After each phase, run the stated DoD check and paste/log its real output —
  don't mark a phase done from assumption.
- Prefer official upstream documentation and container images for Open5GS,
  UERANSIM, K3s, and NVIDIA GPU Operator over ad hoc reimplementation.
- If a DoD check fails and the cause is a hardware/driver/OS-level blocker
  outside the repo's control (e.g., driver/kernel mismatch, secure boot
  interference, insufficient VRAM for a chosen model), stop and clearly report
  the blocker and options — do not silently substitute a workaround that
  changes the architecture without flagging it first.
- Keep all secrets, certificates, and environment-specific values out of git;
  use `.env.example` as the template and `.gitignore` the real `.env`.
- Commit incrementally per phase (one logical commit or small set of commits
  per phase), with commit messages referencing the phase number, so progress is
  easy to review.
