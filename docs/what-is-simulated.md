# What is real vs. simulated

This lab is a **core-network and edge-compute** lab, not a radio lab. Read
this before drawing conclusions from it about RF/PHY behavior.

| Layer | Status in this lab | Notes |
|---|---|---|
| 5G Core (AMF/SMF/UPF/UDM/etc.) | **Real** | Open5GS — production-grade open-source implementation, same protocols as a commercial core |
| PDU session establishment, NAS/NGAP signaling, GTP-U tunneling | **Real** | UERANSIM implements real control-plane procedures against Open5GS |
| Radio/PHY layer (OFDM, antennas, scheduling, HARQ) | **Simulated over UDP** | UERANSIM has no real radio interface — this is the one deliberate gap |
| IP data path (video traffic through the UE's tunnel) | **Real** | Real packets, real TUN interface, real GTP-U encapsulation |
| Edge Kubernetes cluster + GPU scheduling | **Real** | minikube with the host GPU passed through (K3s + GPU Operator as a bare-metal alternative) |
| Video ingestion + inference | **Real** | Real decoding and object detection (YOLOv8n, CPU), real vision-language model on the GPU (llama.cpp + Qwen2-VL-2B) |
| Phone camera | **Real video, simulated device** | ffmpeg inside the UERANSIM UE container streams a video file as if it were the camera |
| "Central cloud" (lab portal's Edge ↔ Central switch) | **Emulated distance** | The path through the internet DNN and the UPF's NAT is real; the long-haul WAN is a relay adding a configurable delay, then the same AI. The WSL2 kernel has no `netem`, hence a relay. The UI labels it as emulated |
| Round-trip / time-to-insight numbers in the portal | **Measured** | HTTP requests from inside the UE over each PDU session; detection and VLM times from the live pipeline |
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
| minikube (or K3s) single node | Cell-site or aggregation-site edge Kubernetes cluster |
| NVIDIA device plugin (minikube) / GPU Operator (K3s) | Same GPU exposure model used in production edge K8s clusters |
| llama.cpp + small VLM (Qwen2-VL-2B) | Metropolis VSS-style RT-VLM microservice, larger GPU/model in production |
| Prometheus + Grafana (+ a small nvidia-smi exporter standing in for DCGM on WSL2) | Same stack with DCGM, at production scale |
