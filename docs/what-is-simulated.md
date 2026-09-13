# What is real vs. simulated

This lab is a **core-network and edge-compute** lab, not a radio lab. Read
this before drawing conclusions from it about RF/PHY behavior.

| Layer | Status in this lab | Notes |
|---|---|---|
| 5G Core (AMF/SMF/UPF/UDM/etc.) | **Real** | Open5GS — production-grade open-source implementation, same protocols as a commercial core |
| PDU session establishment, NAS/NGAP signaling, GTP-U tunneling | **Real** | UERANSIM implements real control-plane procedures against Open5GS |
| Radio/PHY layer (OFDM, antennas, scheduling, HARQ) | **Simulated over UDP** | UERANSIM has no real radio interface — this is the one deliberate gap |
| IP data path (video traffic through the UE's tunnel) | **Real** | Real packets, real TUN interface, real GTP-U encapsulation |
| Edge Kubernetes cluster + GPU scheduling | **Real** | K3s + NVIDIA GPU Operator on real hardware |
| Video ingestion + inference (DeepStream/VLM) | **Real** | Real GPU compute, real model output |
| Multi-site geographic distribution, AI-RAN GPU sharing with baseband | **Out of scope** | Single machine; no real baseband workload exists to share the GPU with |

## Why this split is the right scope

The question this lab is meant to answer is about **edge compute placement
and GPU sizing at a 5G edge site** — not radio engineering. Everything from
NAS/NGAP signaling through GTP-U tunneling through the UPF's local breakout
through Kubernetes GPU scheduling through VLM inference is exercised with
real, production-grade open-source implementations of those exact protocols
and systems. The only thing not real is the RF/PHY layer, which:

- would require SDR hardware and (in most jurisdictions) a radio license or
  shielded environment to do legally and safely, and
- doesn't change any of the answers this lab is built to produce (GPU
  latency/throughput/saturation numbers, and whether the core-to-edge data
  path design works end to end).

## Mapping to a real deployment

| This lab | Production equivalent |
|---|---|
| UERANSIM UE + gNB | Real UE + real gNodeB (RF/PHY handled by RAN vendor hardware) |
| Open5GS AMF/SMF/UPF/etc. | A commercial or open-source 5G core (same 3GPP interfaces) |
| UPF `edge` DNN, no NAT | UPF local breakout / N6 to a MEC/edge site |
| K3s single node | Cell-site or aggregation-site edge Kubernetes cluster |
| NVIDIA GPU Operator | Same tooling used in production edge K8s clusters |
| vLLM + small VLM | Metropolis VSS-style RT-VLM microservice, larger GPU/model in production |
| Prometheus + DCGM + Grafana | Same stack, same metrics, at production scale |
