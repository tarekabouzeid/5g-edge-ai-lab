# Architecture

## Networking decision (Phase 0)

Everything in this lab runs as **containers on a single Docker host**, on one
custom bridge network (`open5gscore`, `10.10.0.0/24`) with static IPs, rather
than in separate VMs. This was chosen over VM-per-tier isolation because:

- Open5GS and UERANSIM's own sample configs (and the most widely used
  community deployments — `herlesupreeth/docker_open5gs`, `gradiant/open5gs`)
  assume static, mutually-reachable IPs for SBI/NGAP/GTP-U; a flat Docker
  bridge network reproduces that with the least moving parts.
- A single host keeps the GPU (needed only by the K3s/edge tier) directly
  attached without PCIe passthrough into a VM.
- The trade-off is weaker network isolation between "core" and "edge" than a
  real deployment would have — acceptable here per the project's own
  non-goals (this is not a security-hardened deployment).

K3s itself runs **natively on the host** (not inside Docker/Docker-in-Docker),
per `edge/k3s-install.sh`, so it gets an unmediated view of the GPU for the
NVIDIA GPU Operator and normal `containerd` CRI behavior. The Open5GS/
UERANSIM containers and the K3s cluster share the same host and its network
namespace at the OS level, which is how Phase 3's local breakout is able to
route from the UPF straight to a K3s Service without another hop.

## Static IP map (`open5gscore`, `10.10.0.0/24`)

| Address | Component | Role |
|---|---|---|
| 10.10.0.1 | (docker bridge gateway) | = the host, from every container's point of view |
| 10.10.0.2 | mongodb | subscriber store (UDR/UDM/PCF backing DB) |
| 10.10.0.4 | smf | session management |
| 10.10.0.5 | amf | N2/NGAP + registration/mobility |
| 10.10.0.7 | upf | N3/GTP-U + N6 breakout |
| 10.10.0.10 | nrf | NF registration/discovery |
| 10.10.0.11 | ausf | authentication |
| 10.10.0.12 | udm | subscriber data management |
| 10.10.0.13 | pcf | policy control |
| 10.10.0.14 | nssf | slice selection |
| 10.10.0.15 | bsf | binding support |
| 10.10.0.20 | udr | subscriber data repository (Mongo-backed) |
| 10.10.0.50 | ueransim-gnb | simulated gNB |
| 10.10.0.51 | ueransim-ue | simulated UE |
| 10.10.0.100 | webui | Open5GS WebUI (subscriber management) |
| 10.10.0.200 | scp | SBI message routing between all NFs |

This mirrors the last-octet convention Open5GS's own default (loopback)
configs use (`.4`=SMF, `.5`=AMF, `.7`=UPF, `.10`=NRF, …, `.200`=SCP), so the
config files here read the same way as upstream documentation and examples.

## Data path

```
uesimtun0 (UE, 10.45.x.x)          uesimtun1 (UE, 10.47.x.x)
      |  internet DNN                   |  edge DNN
      v                                 v
  UERANSIM gNB (10.10.0.50) --N2/NGAP-- Open5GS AMF (10.10.0.5)
      |
      +--N3/GTP-U--> Open5GS UPF (10.10.0.7)
                          |                       \
                    ogstun (10.45.0.0/16)     ogstun2 (10.47.0.0/16)
                    MASQUERADE -> internet    no NAT -> host -> K3s edge segment
```

See `docs/what-is-simulated.md` for what's real vs. simulated at each layer,
and `docs/phase-notes/phase-3.md` for how the `edge` DNN's traffic is proven
to stay local (never NAT'd to the internet) via `tcpdump` on the UPF's N6
side.

## Two DNNs, one purpose

`internet` exists only so Phase 1/2 have a trivial, well-understood DoD check
(`ping 8.8.8.8` through the tunnel). `edge` is the DNN that actually matters
for this project: its UE subnet (`10.47.0.0/16`) is deliberately **not**
NAT'd by the UPF, so packets keep their real UE source address all the way to
the K3s ingress — the same property a real local-breakout / MEC deployment
depends on for the edge compute tier to see (and potentially rate-limit or
authorize by) the actual subscriber's address.

## Edge tier

K3s runs as a single node on the same host. The NVIDIA GPU Operator exposes
the GPU as an allocatable Kubernetes resource (`nvidia.com/gpu`). The
ingestion pod (Phase 5) is the first hop reachable from the UPF's `edge` DNN
subnet; it forwards sampled frames to the VLM inference service (Phase 6).
Both are ordinary Kubernetes Deployments/Services — see `edge/manifests/`.

## Observability

Prometheus scrapes each Open5GS NF's built-in metrics endpoint (already
configured with a `metrics.server` block in most `core/config/*.yaml` files)
plus the DCGM exporter for GPU metrics; Grafana visualizes both. See
`monitoring/`.
