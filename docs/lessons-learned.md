# Lessons Learned — mapping this lab to a real deployment

This document maps each simulated component in this lab to its real-world
production counterpart, per PROJECT_PLAN.md Phase 12, and records what the
real build on the target host (WSL2, RTX 5070 Ti, 2026-09) actually taught —
see "Observations from the real build" below.

## Component mapping

| This lab | Production equivalent | Notes |
|---|---|---|
| UERANSIM UE + gNB | Real UE + real gNodeB | RF/PHY handled by RAN vendor hardware in production; everything above PHY (NAS, NGAP, GTP-U) is the same protocol stack this lab exercises |
| Open5GS AMF/SMF/UPF/UDM/etc. | A commercial or open-source 5G core | Same 3GPP interfaces (N1/N2/N3/N4/N6, SBI); a production core adds HA, redundancy, and carrier-grade NAT/security that this lab's single-instance-per-NF setup does not |
| UPF `edge` DNN, un-NAT'd | UPF local breakout / N6 to a MEC or edge site | This lab's version is the minimum viable version of the same idea: keep the subscriber's traffic local instead of backhauling to a central core |
| minikube single node | Cell-site or aggregation-site edge Kubernetes cluster | Production would run a hardened, HA control plane and likely a CNI/service mesh choice driven by the operator's existing platform, not a lab-friendly single node |
| NVIDIA device plugin (minikube) | Same `nvidia.com/gpu` exposure model (production often deploys it via the GPU Operator) | Directly transferable — `nvidia.com/gpu` scheduling is the same mechanism production edge K8s clusters use |
| GStreamer/OpenCV + YOLOv8n ingestion | NVIDIA DeepStream / Metropolis pipeline | This lab's default deliberately trades DeepStream's higher performance and NVDEC/NVENC hardware offload for something that doesn't need driver/CUDA/TensorRT version verification against unknown hardware (see phase-5.md); a real deployment sized for throughput would very likely want DeepStream |
| llama.cpp + Gemma 4 E4B (GGUF) | Metropolis VSS-style RT-VLM microservice | Same serving pattern (OpenAI-compatible API in front of an open VLM); this lab deliberately picked a small (~4.5B effective) model for low VRAM/fast iteration over caption accuracy — production would use a larger GPU (e.g. RTX PRO 6000) and a larger/fine-tuned model |
| Prometheus + Grafana + nvidia-smi exporter | Same stack with DCGM, at production scale | Directly transferable (DCGM replaces the stand-in exporter off WSL2); production adds alerting, longer retention, and multi-cluster federation |

## Observations from the real build

- **The 5G core and local breakout were the easy part.** Open5GS + UERANSIM
  registered and carried traffic on the first real bring-up once config
  paths were right; the un-NAT'd edge DNN reached the edge cluster with the
  UE's own address intact (measured ~1–2 ms round trip from the UE).
- **The GPU platform was the hard part.** K3s + GPU Operator on WSL2 failed
  in three independent ways (NFD can't see the paravirtualized GPU, mount
  propagation, containerd config); minikube with `--gpus` just worked.
  vLLM hung on WSL2's GPU passthrough while raw CUDA and llama.cpp were fine.
  For a pilot: validate the *exact* serving stack on the *exact* host
  platform early — it is not a detail.
- **One GPU, one consumer.** Running detection on CPU and giving the GPU to
  the VLM alone removed the need for time-slicing at this scale; a small VLM
  answers in ~0.2–0.7 s. GPU sharing (MIG/time-slicing) only becomes
  necessary with several GPU workloads per site.
- **Simulated RAN has its own failure modes.** UERANSIM's data path can stall
  after long runs (upstream issue #757) and the tunnel ↔ DNN mapping changes
  between attaches; anything scripted must pick interfaces by subnet and be
  able to re-attach. Real UEs don't behave like this — don't mistake
  simulator artefacts for network findings.
- **Edge vs central, measured.** With the same phone, AI and video, only the
  exit point changed: ~1.5 ms round trip at the edge vs ~50 ms with a
  25 ms-each-way WAN (emulated). For interactive AI (alerts, "ask the
  camera") that difference is the whole case for local breakout.

## Open questions for the real pilot (to answer once this lab has real numbers)

- What GPU utilization/VRAM headroom does a single VLM instance actually
  need at the target model size, and how does that change the sizing
  conversation for co-locating GPU inference with a baseband workload?
- At what concurrent-stream count does this class of GPU saturate for this
  class of model (the lab portal's live latency and GPU numbers are the starting point), and how
  does that map to the subscriber density expected at a real cell site vs.
  aggregation site?
- How much of the local-breakout latency (Phase 3/7) is UPF/GTP-U overhead
  vs. Kubernetes networking overhead vs. inference time itself? Worth
  instrumenting separately in a follow-up if the pilot's latency budget is
  tight.
