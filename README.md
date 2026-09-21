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

Real host: Ubuntu 22.04/24.04 (bare metal, VM, **or WSL2 on Windows** — see
"Running on WSL2" below, it needs a few extra one-time steps), Docker +
Compose v2, NVIDIA driver + Container Toolkit, `helm`, `kubectl`, sudo. Local
dev/test only (no GPU): Docker + `kind`. All image/package versions are
pinned to latest-as-of-2026-09-13 in `.env.example`; re-check anytime with
`./scripts/check-latest-versions.sh`.

## Running on WSL2

A stock/"vanilla" WSL2 Ubuntu install is missing a few things this repo
needs that a bare-metal Ubuntu host normally has out of the box. Do this
**once**, before your first `./lab.sh ... up`, even if `nvidia-smi` already
works on the WSL2 host itself:

```bash
# 1. GPU passthrough into Docker containers needs the NVIDIA Container
#    Toolkit installed INSIDE the WSL distro (the Windows-side driver alone
#    is not enough) — install it, then verify:
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo service docker restart
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi   # must succeed before continuing

# 2. K3s's containerd needs the root filesystem's mount propagation to be
#    "shared", which WSL2 does not set by default — without this, the GPU
#    Operator's toolkit pod fails with "not a shared or slave mount".
#    NOT persistent across a WSL restart (wsl --shutdown / reboot) — re-run
#    this (or check with `findmnt -o TARGET,PROPAGATION /`) any time GPU
#    Operator pods start failing again after a restart.
sudo mount --make-rshared /
```

SCTP (needed for `ran/`'s NGAP signaling) is compiled directly into the
WSL2 kernel already — nothing to install there, despite what
`docs/phase-notes/phase-0.md`'s original build-sandbox caveat says (that was
about a different, more restricted environment; see that file for the
distinction).

`./lab.sh k3s up` (or `all up`) will run, but the GPU Operator step needs
two extra flags on this platform because WSL2 can't be auto-detected as a
GPU node the normal way (Node Feature Discovery sees the GPU as PCI vendor
`1414`/Microsoft, never `10de`/NVIDIA, since WSL2 paravirtualizes GPU access
rather than exposing a real PCI device). If `kubectl -n gpu-operator get
pods` only ever shows the operator + node-feature-discovery pods (no
toolkit/device-plugin/gpu-feature-discovery daemonsets appear), re-run the
install with:

```bash
helm upgrade --install gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace \
  --set driver.enabled=false \
  --set nfd.enabled=false \
  --set 'toolkit.env[0].name=CONTAINERD_CONFIG' \
  --set 'toolkit.env[0].value=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl' \
  --set 'toolkit.env[1].name=CONTAINERD_SOCKET' \
  --set 'toolkit.env[1].value=/run/k3s/containerd/containerd.sock' \
  --set 'toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS' \
  --set 'toolkit.env[2].value=nvidia' \
  --set 'toolkit.env[3].name=CONTAINERD_SET_AS_DEFAULT' \
  --set-string 'toolkit.env[3].value=true'
kubectl label node <your-node> nvidia.com/gpu.present=true feature.node.kubernetes.io/pci-10de.present=true --overwrite
```

Full details and why each flag is needed: `docs/phase-notes/phase-4.md`'s
"Known risks" section.

## Quickstart — real host (full stack, GPU required)

```bash
cp .env.example .env
```

At minimum, set `EDGE_NODE_IP` in `.env` — everything else has a workable
default for a lab. `GRAFANA_ADMIN_PASSWORD`'s `CHANGE_ME` default is fine to
leave as-is for this kind of local/internal-only lab use; change it only if
you're exposing Grafana beyond your own machine.

`EDGE_NODE_IP` must be an address this host actually owns — it's what K3s's
NodePort services (RTSP ingest, Grafana) bind on and what the simulated
UE's edge-DNN traffic routes back through:

- **Bare-metal/VM host:** your real LAN IP — `ip addr` or `hostname -I`.
- **WSL2 host:** WSL2's *own* IP, not the Windows host's LAN IP — run
  `hostname -I` inside the WSL distro and take the first address shown.
  This will also match K3s's own node `INTERNAL-IP` once `./lab.sh k3s up`
  has run (verify with `kubectl get nodes -o wide`).

```bash
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
for whatever fails before troubleshooting from scratch. **On WSL2**, do the
one-time setup in "Running on WSL2" above first, or the K3s/GPU-Operator
step will fail partway through.

`lab.sh` and the scripts it wraps run plenty of `sudo` commands (K3s
install, host routing, `mount --make-rshared`). If you're driving this
through Claude Code rather than a normal terminal, expect to be handed
those specific commands to run yourself — a coding-agent session has no way
to answer an interactive sudo password prompt.

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

## Try it: stream video through the simulated UE to the VLM

Once Phases 1–6 are up on a real host, see
[`docs/phase-notes/phase-7.md`](docs/phase-notes/phase-7.md) for the exact
commands to push a video into the simulated UE's tunnel and watch a
VLM-generated caption come out at the edge.

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
