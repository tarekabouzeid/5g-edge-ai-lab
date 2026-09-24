# 5G Edge AI Home Lab

[![CI](https://github.com/tarekabouzeid/Edge-compute-Open5GS-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/tarekabouzeid/Edge-compute-Open5GS-lab/actions/workflows/ci.yml)

<img width="1159" height="475" alt="image" src="https://github.com/user-attachments/assets/5a75b72b-bf81-44e1-924c-36ffcdff162e" />


A home-lab simulation of a full **UE → 5G RAN → Core → Edge Kubernetes →
GPU/VLM** data path, built entirely from open-source software. No SDR/RF
hardware is used or required — the radio layer is simulated over IP
(UERANSIM); everything else (5G core signaling, GTP-U tunneling, Kubernetes
GPU scheduling, video ingestion, VLM inference) is real. See
[`docs/what-is-simulated.md`](docs/what-is-simulated.md) for the exact
boundary and [`PROJECT_PLAN.md`](PROJECT_PLAN.md) for the full build brief.

## Status

**Running end to end on real hardware** (WSL2 Ubuntu 24.04 on Windows, NVIDIA
RTX 5070 Ti, 2026-09): a simulated phone registers on the real Open5GS core,
streams video over its `edge` data session through the UPF's local breakout
(no NAT) into a minikube edge cluster, where object detection and a GPU
vision-language model describe the scene — driven and shown by a lab portal
(`portal/`, http://localhost:8090). Each phase's verified evidence is in
`docs/phase-notes/phase-N.md`; CI (badge above) lints everything and brings up
the Open5GS core on every push. Not yet done: the Phase 9 benchmark report.

## Requirements

- **Ubuntu 22.04/24.04** — bare metal, VM, or **WSL2** (the verified host).
- **Docker** + Compose v2, **NVIDIA driver** + **NVIDIA Container Toolkit**
  (Docker must list an `nvidia` runtime — see "Running on WSL2").
- **minikube** and **kubectl** (the edge cluster, verified path).
- Optional: `helm` + sudo for the K3s alternative; `kind` for the no-GPU dev path.
- Disk: ~25 GB for images (the ingest image's PyTorch/CUDA base is ~7 GB)
  plus ~2 GB for the VLM's model cache.

All versions are pinned in `.env.example` / the manifests; check for drift
with `./scripts/check-latest-versions.sh`.

## Running on WSL2

One-time, even if `nvidia-smi` already works in WSL2: GPU passthrough into
Docker containers needs the NVIDIA Container Toolkit installed *inside* the
distro (the Windows-side driver alone is not enough):

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo service docker restart
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi   # must succeed before continuing
```

SCTP (needed for the RAN's NGAP signaling) is already compiled into the
WSL2 kernel. That's all the minikube path needs — no other sudo steps.

<details>
<summary>K3s + GPU Operator on WSL2 (alternative path — extra steps, not the verified one)</summary>

K3s's containerd needs the root filesystem's mount propagation to be
"shared", which WSL2 does not set by default (not persistent across a WSL
restart):

```bash
sudo mount --make-rshared /
```

The GPU Operator also can't auto-detect the GPU on WSL2 (Node Feature
Discovery sees PCI vendor `1414`/Microsoft, never `10de`/NVIDIA). If
`kubectl -n gpu-operator get pods` never shows the toolkit/device-plugin
daemonsets, re-install with:

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

Details: `docs/phase-notes/phase-4.md`'s "Known risks". Even with these,
vLLM hung on this platform — the VLM now runs on llama.cpp either way.
</details>

## Quickstart — the whole lab from scratch (GPU host)

```bash
cp .env.example .env        # defaults work for the minikube path
./lab.sh all up             # core -> RAN -> minikube+GPU -> edge apps -> breakout -> monitoring -> portal
```

Then open **http://localhost:8090** (also from the Windows browser on WSL2).
`./lab.sh all up` is idempotent and takes ~2 minutes once images and the
model are cached; the very first run downloads ~10 GB (the ingest base
image is pulled on the host and loaded into minikube, the VLM model on first
start). What it runs, in order:

1. `core up` — Open5GS (11 NFs + MongoDB + WebUI), then provisions the test
   subscriber with both the `internet` and `edge` DNN sessions (Phase 1).
2. `ran up` — UERANSIM gNB + UE, waits for both PDU sessions and pings out
   through the internet one (Phase 2).
3. `minikube up` — minikube with GPU passthrough, the VLM model cache, and
   the `edge-ingest` image built into it (Phase 4).
4. `edge-apps up` — RTSP gateway, ingest (CPU detection), VLM (GPU) (Phases 5–6).
5. `breakout up` — local-breakout routing UE → UPF → edge node, no NAT (Phase 3).
6. `monitoring up` — Prometheus + Grafana (Phase 8).
7. `portal up` — lab portal + GPU exporter; fetches sample clips into `demo-media/`.

```bash
./lab.sh status             # anytime
./lab.sh all down           # non-destructive: stops everything, keeps data and caches
./lab.sh                    # every per-layer target
```

`.env` settings you may want: `GRAFANA_ADMIN_PASSWORD` (Grafana is reached
with `kubectl port-forward --address 0.0.0.0 svc/grafana 3000:3000`),
`MINIKUBE_CPUS` / `MINIKUBE_MEMORY`, and `EDGE_NODE_IP` (only used by
`scripts/stream-test-video.sh` / `benchmark.py`; on minikube it's `minikube ip`).

**Bare-metal Linux with K3s instead:** `./lab.sh all up --k3s`, then run
`./edge/setup-local-breakout-route.sh` (needs sudo) — see
`docs/phase-notes/phase-3.md` and `phase-4.md`. If you drive any of this
through Claude Code, sudo steps are handed to you to run yourself.

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

## Present it: the lab portal

http://localhost:8090 after `./lab.sh all up` (or `./lab.sh portal up`): one
screen with the simulated phone (power on/off, camera, video gallery and
upload), the 5G core's live topology and signalling timeline (parsed from
the network functions' own logs), and the edge AI — annotated video, scene
descriptions, **Ask the camera**, and **alert rules** (zones drawn on the
video, object counts, yes/no questions to the VLM). An *Edge breakout ↔
Central cloud* switch moves the video between the two data sessions and
shows measured round trips. See [`docs/demo.md`](docs/demo.md) for the
presenter flow; manual end-to-end steps are in
[`docs/phase-notes/phase-7.md`](docs/phase-notes/phase-7.md).

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
| `edge/` | 3–6 | minikube + GPU bring-up (verified path), local-breakout routing, K3s+GPU Operator and KIND alternatives, ingestion image + gateway/ingest/VLM manifests |
| `monitoring/` | 8 | Prometheus, Grafana, DCGM exporter (K3s) — on minikube a host nvidia-smi exporter feeds the GPU panels |
| `portal/` | 7 | Lab portal: host-side controller (UE control, NF-log timeline, central-cloud relay, alert rules) + single-screen UI; also runs the GPU exporter |
| `scripts/` | 1,2,5,7,9 | Subscriber provisioning, PDU-session check, test/demo video streaming, sample-clip fetch, GPU exporter, benchmark, version check |
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
