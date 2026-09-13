# Lessons Learned — mapping this lab to a real deployment

This document maps each simulated component in this lab to its real-world
production counterpart, per PROJECT_PLAN.md Phase 12. It will be filled in
with actual observations (what worked, what didn't, what surprised us) once
the lab has been built and run for real on the target host — see
`docs/phase-notes/phase-0.md` for why that hasn't happened yet from this
build session.

## Component mapping

| This lab | Production equivalent | Notes |
|---|---|---|
| UERANSIM UE + gNB | Real UE + real gNodeB | RF/PHY handled by RAN vendor hardware in production; everything above PHY (NAS, NGAP, GTP-U) is the same protocol stack this lab exercises |
| Open5GS AMF/SMF/UPF/UDM/etc. | A commercial or open-source 5G core | Same 3GPP interfaces (N1/N2/N3/N4/N6, SBI); a production core adds HA, redundancy, and carrier-grade NAT/security that this lab's single-instance-per-NF setup does not |
| UPF `edge` DNN, un-NAT'd | UPF local breakout / N6 to a MEC or edge site | This lab's version is the minimum viable version of the same idea: keep the subscriber's traffic local instead of backhauling to a central core |
| K3s single node | Cell-site or aggregation-site edge Kubernetes cluster | Production would run a hardened, HA control plane and likely a CNI/service mesh choice driven by the operator's existing platform, not K3s's lab-friendly defaults |
| NVIDIA GPU Operator | Same tooling, same GPU exposure model | Directly transferable — this is genuinely the same mechanism production edge K8s clusters use |
| GStreamer/OpenCV + YOLOv8n ingestion | NVIDIA DeepStream / Metropolis pipeline | This lab's default deliberately trades DeepStream's higher performance and NVDEC/NVENC hardware offload for something that doesn't need driver/CUDA/TensorRT version verification against unknown hardware (see phase-5.md); a real deployment sized for throughput would very likely want DeepStream |
| vLLM + Qwen2-VL-7B | Metropolis VSS-style RT-VLM microservice | Same serving pattern (OpenAI-compatible API in front of an open VLM); production would likely use a larger GPU (e.g. RTX PRO 6000) and a larger/fine-tuned model |
| Prometheus + DCGM + Grafana | Same stack, same metrics, at production scale | Directly transferable; production adds alerting, longer retention, and multi-cluster federation |

## Open questions for the real pilot (to answer once this lab has real numbers)

- What GPU utilization/VRAM headroom does a single VLM instance actually
  need at the target model size, and how does that change the sizing
  conversation for co-locating GPU inference with a baseband workload?
- At what concurrent-stream count does this class of GPU saturate for this
  class of model (see `docs/benchmark-results.md` once generated), and how
  does that map to the subscriber density expected at a real cell site vs.
  aggregation site?
- How much of the local-breakout latency (Phase 3/7) is UPF/GTP-U overhead
  vs. Kubernetes networking overhead vs. inference time itself? Worth
  instrumenting separately in a follow-up if the pilot's latency budget is
  tight.
