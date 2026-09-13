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
| `CLAUDE.md` | — | Repo-specific guidance for Claude Code sessions (commands, architecture, what can't run sandboxed) |

## Glossary — telecom abbreviations used in this repo

<details>
<summary>Expand for a definition and where each one is actually used here</summary>

**Core network functions** (each one is its own container in `core/docker-compose.yml`, configured by the matching `core/config/*.yaml`)

| Term | Full name | Used here as |
|---|---|---|
| AMF | Access and Mobility Management Function | Handles UE registration and mobility over N2; `core/config/amf.yaml`, IP `10.10.0.5` |
| SMF | Session Management Function | Manages PDU sessions, allocates UE IPs, tells the UPF how to route them; `core/config/smf.yaml`, IP `10.10.0.4` |
| UPF | User Plane Function | Terminates the GTP-U tunnel and forwards subscriber traffic; the one NF with a real TUN device (`ogstun`/`ogstun2`) and the NAT-vs-no-NAT split that makes Phase 3's local breakout work; IP `10.10.0.7` |
| NRF | NF Repository Function | Service registry every NF registers with so others can discover it; IP `10.10.0.10` |
| SCP | Service Communication Proxy | Mediates all inter-NF SBI calls so NFs only need to know the SCP's address, not each other's — the architecture choice documented in `docs/phase-notes/phase-1.md`; IP `10.10.0.200` |
| AUSF | Authentication Server Function | Runs the 5G-AKA authentication exchange with the UE; IP `10.10.0.11` |
| UDM | Unified Data Management | Subscriber data logic (auth vectors, subscription profile); IP `10.10.0.12` |
| UDR | Unified Data Repository | The actual MongoDB-backed subscriber store UDM/PCF read from; `db_uri: mongodb://10.10.0.2/open5gs`, IP `10.10.0.20` |
| PCF | Policy Control Function | Session/QoS policy decisions; IP `10.10.0.13` |
| BSF | Binding Support Function | Tracks which PCF is handling which session, for policy binding lookups; IP `10.10.0.15` |
| NSSF | Network Slice Selection Function | Picks which slice (S-NSSAI) serves a UE; IP `10.10.0.14` |
| NF | Network Function | Generic term for any of the above — "all NFs healthy" in `docs/phase-notes/` and `ci.yml` means all 11 core containers |
| HSS | Home Subscriber Server | The 4G/legacy equivalent of UDM — mentioned once in `PROJECT_PLAN.md` as "UDM/HSS", not a component actually deployed here |

**RAN, UE identity, and slicing** (mostly in `ran/*.yaml`, `core/config/amf.yaml`, `scripts/provision-subscriber.sh`)

| Term | Full name | Used here as |
|---|---|---|
| gNB | next-generation Node B (5G base station) | Simulated by UERANSIM in `ran/docker-compose.yml`; talks NGAP to the AMF and GTP-U to the UPF, no real radio |
| UE | User Equipment | The simulated phone (UERANSIM's `nr-ue`), configured in `ran/ue-config.yaml` with the test subscriber's identity/keys |
| RAN | Radio Access Network | The gNB+UE pair; "RAN" in this repo always means UERANSIM's simulated version, per `docs/what-is-simulated.md` |
| PLMN | Public Land Mobile Network | The operator identity (MCC+MNC); this lab uses the 3GPP-reserved test PLMN `999/70` everywhere |
| MCC | Mobile Country Code | `999` (test value) in every `core/config/*.yaml` and `ran/*.yaml` |
| MNC | Mobile Network Code | `70` (test value), paired with MCC above |
| TAC | Tracking Area Code | `tac: 1` in `amf.yaml` and `gnb-config.yaml` — must match between core and RAN or registration fails |
| TAI | Tracking Area Identity | PLMN + TAC together; what `amf.yaml`'s `tai:` block declares as served |
| GUAMI | Globally Unique AMF Identifier | Identifies this specific AMF instance; `amf.yaml`'s `guami:` block (region 2, set 1) |
| IMSI | International Mobile Subscriber Identity | The test subscriber's permanent ID, `999700000000001` in `.env.example` (`TEST_IMSI`) and `ran/ue-config.yaml` |
| SUPI | Subscription Permanent Identifier | 5G's generalized form of IMSI — same value, 5G terminology |
| SUCI | Subscription Concealed Identifier | The encrypted-over-the-air form of SUPI; this lab uses `protectionScheme: 0` (null scheme, no encryption) in `ue-config.yaml`, so SUCI is sent unconcealed — deliberate simplification, see the comment there |
| K | subscriber key | The shared secret authenticating the UE, `TEST_KEY` in `.env.example` |
| OPC | Operator Code (derived) | Operator-specific authentication parameter, `TEST_OPC` in `.env.example`, paired with K |

**Session, slice, and QoS** (`core/config/smf.yaml`, `upf.yaml`, `ue-config.yaml`)

| Term | Full name | Used here as |
|---|---|---|
| PDU (session) | Protocol Data Unit session | The UE's actual data connection — one per DNN; Phase 2's DoD is a successful PDU session establishment |
| DNN | Data Network Name | Which network a PDU session reaches — this lab defines two: `internet` (NAT'd) and `edge` (not NAT'd, the local-breakout path) |
| APN | Access Point Name | Older/4G term for the same concept as DNN; `open5gs-dbctl`'s CLI and this repo's scripts use "APN" in argument names even though the NFs speak "DNN" |
| S-NSSAI | Single Network Slice Selection Assistance Information | Identifies a network slice (SST + optional SD); every config here uses one slice, `sst: 1` |
| SST | Slice/Service Type | The slice type number; `1` (eMBB-equivalent test value) everywhere in this repo |
| SD | Slice Differentiator | Optional extra slice qualifier; set to `1` in `ue-config.yaml`'s default NSSAI |
| QoS | Quality of Service | General term for traffic-handling guarantees; not tuned in this lab beyond Open5GS's defaults |
| 5QI | 5G QoS Identifier | Standardized QoS class number; left at Open5GS defaults, not explicitly set in this repo's configs |
| ARP | Allocation and Retention Priority | Session priority/preemption parameter; left at Open5GS defaults, not explicitly set in this repo's configs |
| AMBR | Aggregate Maximum Bit Rate | Per-subscriber/session bandwidth cap; left at Open5GS defaults, not explicitly set in this repo's configs |

**Interfaces and protocols** (the arrows in `docs/architecture.md`'s data-path diagram)

| Term | Full name | Used here as |
|---|---|---|
| SBI | Service-Based Interface | The HTTP/2 API every core NF uses to talk to every other NF, routed via the SCP |
| NGAP | NG Application Protocol | The N2 signaling protocol between gNB and AMF (registration, PDU session setup) |
| NAS | Non-Access Stratum | The UE↔AMF signaling layer carried inside NGAP (registration/authentication messages) |
| GTP-U | GPRS Tunneling Protocol – User plane | Encapsulates actual subscriber IP packets between gNB and UPF; this is the tunnel `ogstun`/`ogstun2` terminate |
| PFCP | Packet Forwarding Control Protocol | SMF↔UPF control channel telling the UPF how to handle a session's packets |
| SCTP | Stream Control Transmission Protocol | Transport under NGAP; needs a kernel module (`modprobe sctp`) — confirmed absent in the original build sandbox, loaded explicitly in `ci.yml` |
| N1 / N2 / N3 / N4 / N6 | 3GPP reference points | N1: UE↔AMF (NAS); N2: gNB↔AMF (NGAP); N3: gNB↔UPF (GTP-U); N4: SMF↔UPF (PFCP); N6: UPF↔external/edge network — N6 is specifically the local-breakout link in `docs/architecture.md` |

</details>

## Non-goals

No real RF/SDR transmission, no multi-cell handover, no AI-RAN GPU sharing
with a real baseband workload, and no security hardening beyond keeping
secrets out of git. See `PROJECT_PLAN.md` Section 8.

## License

MIT — see [`LICENSE`](LICENSE).
