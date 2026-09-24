# Phase 11 — Stretch: GPU Multi-Tenancy

## Status: Not needed at current scale — resolved by design, 2026-09-24

The blocking conflict below (two Deployments each requesting a whole GPU)
was removed by giving the single GPU to the VLM alone and running YOLOv8n on
CPU (see phase-5.md); both now run side by side on one GPU. Time-slicing /
MPS below stays the plan for when a site needs several GPU workloads.

## Approach (design only — not yet implemented)

`edge/manifests/ingest-deployment.yaml` and `vlm-deployment.yaml` currently
each request a full `nvidia.com/gpu: 1` — on a single-GPU host, Kubernetes
will refuse to schedule both at once under the default (whole-GPU) device
plugin, since only one `1`-count GPU resource exists to hand out.

To run both concurrently on one physical GPU, the NVIDIA GPU Operator
supports two mechanisms, configured at Operator-install time
(`edge/install-gpu-operator.sh`), not per-pod:

1. **Time-slicing** (works on any recent NVIDIA GPU/driver): configure a
   `ConfigMap` telling the device plugin to advertise the one physical GPU
   as N schedulable replicas, e.g.:

   ```yaml
   version: v1
   flags:
     migStrategy: none
   sharing:
     timeSlicing:
       resources:
         - name: nvidia.com/gpu
           replicas: 2
   ```

   applied via `helm upgrade gpu-operator nvidia/gpu-operator ... --set-file
   devicePlugin.config.name=time-slicing-config`. Both pods keep requesting
   `nvidia.com/gpu: 1`, but Kubernetes now sees 2 allocatable units instead
   of 1 — they share the GPU's compute at the driver level (no VRAM
   isolation), which is the intended trade-off for this lab.

2. **MPS** (NVIDIA Multi-Process Service): gives better isolation than raw
   time-slicing; the Operator supports it via `cuda-mps` device-plugin config
   in newer releases — check the installed Operator version's docs, since
   this has moved between chart versions.

## DoD (once implemented)

- [ ] both `edge-ingest` and `vlm` pods are `Running` simultaneously
      (`kubectl get pods`), not one Pending on insufficient GPU resource
- [ ] `nvidia-smi` on the host shows both processes resident on the same GPU
- [ ] neither workload's latency degrades to the point of failing its own
      phase's DoD (Phase 5's detection loop, Phase 6's scene descriptions) while the
      other is under load — document the actual degradation observed, since
      *some* slowdown from sharing is expected and the point of this phase
      is to characterize it, not eliminate it
