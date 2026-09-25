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

The edge Kubernetes cluster is **minikube on the Docker driver** with the
host GPU passed through (`--gpus=nvidia.com`, `edge/minikube-up.sh`) — the
path verified end to end on the WSL2 + RTX 5070 Ti host. K3s running
natively with the NVIDIA GPU Operator (`edge/k3s-install.sh`) is kept as an
alternative for bare-metal Linux but hit repeated WSL2-specific failures
(`docs/phase-notes/phase-4.md`). minikube's node is itself a container on
its own Docker network (`minikube`, `192.168.49.0/24`); the local breakout
connects the two worlds by attaching the UPF container to that network too
(`edge/setup-minikube-breakout.sh`), so edge-DNN packets reach the node
directly, un-NAT'd, with no host routing or sudo involved.

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
 UE (UERANSIM, 10.10.0.51)
   uesimtunX 10.45.x.x (internet DNN)      uesimtunY 10.47.x.x (edge DNN)
   (which tunnel gets which DNN varies per attach — always pick by subnet)
      |                                         |
  UERANSIM gNB (10.10.0.50) ---N2/NGAP--- Open5GS AMF (10.10.0.5)
      |
      +---N3/GTP-U---> Open5GS UPF (10.10.0.7, also 192.168.49.3 on "minikube")
                         |                                |
                   ogstun (internet)                ogstun2 (edge)
                   MASQUERADE -> 10.10.0.7          no NAT, src stays 10.47.x.x
                         |                                |
          emulated central cloud:                         |
          WAN-delay relay in the lab portal               |
          (10.10.0.1:30555, +N ms each way)               |
                         |                                v
                         +------------> minikube node 192.168.49.2
                                         NodePort 30554 (externalTrafficPolicy: Local)
                                         -> edge-gateway (mediamtx, RTSP)
                                         -> edge-ingest  (decode + YOLOv8n on CPU,
                                                          NodePort 30080: demo API, MJPEG)
                                         -> vlm          (llama.cpp + Gemma 4 E4B, the GPU)
```

The node's return route `10.47.0.0/16 via 192.168.49.3` sends replies back
through the UPF, so the gateway sees — and logs — the phone's real edge-DNN
address. See `docs/what-is-simulated.md` for what's real vs. simulated at
each layer, and `docs/phase-notes/phase-7.md` for the verified end-to-end run
(`tcpdump` on the UPF's `ogstun2`, the phone's IP in mediamtx's log).

## Two DNNs, one purpose

`internet` exists only so Phase 1/2 have a trivial, well-understood DoD check
(`ping 8.8.8.8` through the tunnel). `edge` is the DNN that actually matters
for this project: its UE subnet (`10.47.0.0/16`) is deliberately **not**
NAT'd by the UPF, so packets keep their real UE source address all the way to
the edge cluster's ingress — the same property a real local-breakout / MEC deployment
depends on for the edge compute tier to see (and potentially rate-limit or
authorize by) the actual subscriber's address.

## Edge tier

One GPU, one GPU consumer: only the `vlm` Deployment requests
`nvidia.com/gpu` (minikube's NVIDIA device plugin advertises it); `edge-ingest`
runs YOLOv8n on CPU, so both run side by side without time-slicing. The VLM
uses the `Recreate` rollout strategy — a rolling update's surge pod could
never schedule next to the old one on a single GPU. Manifests:
`edge/manifests/`.

## Control and presentation: the lab portal

`portal/` runs on the host (Docker, host network, the Docker socket, bound to
127.0.0.1) because driving the simulated phone means `docker exec` into the
UE (`nr-cli`, routes, ffmpeg) and reading the NFs' logs — neither of which
the in-cluster pods can or should do. It also hosts the emulated
central-cloud relay and evaluates alert rules against edge-ingest's API.
`http://localhost:8090`; see `docs/demo.md`.

## Observability

Prometheus (in the cluster) scrapes edge-ingest (frames, detections, VLM
latency), the VLM (llama.cpp's `--metrics`: tokens/s) and a host GPU
exporter (`scripts/host-gpu-exporter.py`, run by the portal's compose file)
that stands in for NVIDIA's DCGM exporter, which doesn't run under WSL2.
The Open5GS NFs' own `/metrics` are not reachable from inside minikube
(Docker blocks cross-bridge traffic to the core network); the lab portal
reads them from the host instead and shows the core counters live. See
`monitoring/` and `docs/phase-notes/phase-8.md`.
