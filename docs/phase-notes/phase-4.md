# Phase 4 — Edge Kubernetes Cluster + GPU (minikube)

## Status: Verified on the WSL2 host (minikube), 2026-09-22 onwards — DoD met

## What was built

- `edge/minikube-up.sh` (`./lab.sh minikube up`, no sudo): starts minikube
  on the Docker driver with the host GPU passed through
  (`--gpus=nvidia.com`), waits for `nvidia.com/gpu` to be allocatable
  (minikube's NVIDIA device plugin addon), creates the VLM model cache
  inside the node (`/opt/edge-lab/hf-cache`), and builds the `edge-ingest`
  image inside minikube's Docker daemon (the multi-GB base image is pulled
  on the host and `minikube image load`ed — long pulls from inside
  minikube's own daemon were seen to stall on this host).
- Idempotent: re-running starts a stopped cluster, leaves a running one
  alone, and rebuilds the ingest image only if its sources changed.
- Optional sizing via `MINIKUBE_CPUS` / `MINIKUBE_MEMORY` in `.env`.

## How to run this for real (on the actual host)

Prerequisite: the NVIDIA Container Toolkit is installed and Docker lists an
`nvidia` runtime (README "Running on WSL2"; `minikube-up.sh` checks this and
stops with a pointer if not).

```bash
./lab.sh minikube up
kubectl get node minikube -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'   # -> 1
```

## DoD

- [x] the node advertises `nvidia.com/gpu: 1` as allocatable
      (`minikube-up.sh` waits for exactly this and fails otherwise)
- [x] a pod requesting `nvidia.com/gpu` actually runs on the GPU — the VLM
      (Phase 6) generates at ~160–230 tokens/s on the RTX 5070 Ti, see
      `docs/phase-notes/phase-6.md`

## Known risks

- **The NVIDIA Container Toolkit isn't in the WSL2 distro by default**, even
  when the Windows driver and `nvidia-smi` already work — without it Docker
  has no `nvidia` runtime and minikube can't pass the GPU through. One-time
  install: README "Running on WSL2".
- **Large image pulls stall inside minikube's daemon** on this host; the
  ingest base image is therefore pulled on the host and loaded in (see
  above). If a host-side `docker pull` itself stalls after ~25–30 minutes,
  killing and re-running it restores full speed (layers already pulled stay
  cached).

## History: why not K3s + GPU Operator

The edge cluster was first built as K3s + the NVIDIA GPU Operator (DoD met
on 2026-09-20), but on WSL2 it kept breaking in three independent ways: the
Operator's Node Feature Discovery can never see the GPU (WSL2 exposes it as
PCI vendor `1414`/Microsoft, not `10de`/NVIDIA) and reverts manual labels;
WSL2's root mount propagation is `private` where the toolkit needs `shared`
(and `mount --make-rshared /` doesn't survive a WSL restart); and K3s's
bundled containerd needs non-default toolkit config paths. minikube with
`--gpus` just worked, needs no sudo, and became the only path. The K3s
scripts, the GPU Operator install and a CPU-only KIND dev path were removed
on 2026-09-25; they (and the exact workarounds) are in git history.
