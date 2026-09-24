# KIND path (local dev/test, no GPU host required)

`kind-up.sh` brings up a local Kubernetes cluster in Docker and deploys the
**CPU-compatible subset** of the edge stack: `edge-gateway` (mediamtx) and
`edge-ingest` (YOLOv8n + FastAPI, running on CPU since KIND has no GPU device
plugin by default) plus Prometheus/Grafana. This is for validating the K8s
manifests, the ingestion pipeline's wiring, and the monitoring stack **without
needing a GPU host** — it's what this repo's CI pipeline uses for its smoke
test (`.github/workflows/ci.yml`).

## What KIND does NOT cover

- **The `vlm` Deployment is not applied.** The VLM (llama.cpp + Qwen2-VL) needs a
  real GPU to be practically usable; running it on CPU would be technically possible but far
  too slow to be a meaningful test. `edge-ingest`'s calls to the VLM will
  just fail/timeout in KIND mode — expected, not a bug.
- **No DCGM/GPU metrics.** Grafana's GPU utilization/memory/temperature
  panels will stay empty.
- **No local-breakout networking (Phase 3).** KIND's networking is entirely
  inside Docker on this host; it doesn't stand in for the real UPF/K3s
  routing path.

Use this to sanity-check Phases 4/5/8's Kubernetes manifests quickly, then
run the real path (`edge/k3s-install.sh` + `edge/install-gpu-operator.sh` +
`edge/manifests/vlm-deployment.yaml`) on the actual host for Phases 6/7/9.

## Usage

```bash
./edge/kind/kind-up.sh      # cluster up, image built+loaded, stack deployed
./scripts/stream-test-video.sh   # EDGE_NODE_IP=localhost in .env
kubectl logs -l app=edge-ingest --tail=50
./edge/kind/kind-down.sh    # tear down
```

## Advanced, unverified: real GPU inside KIND

If the host's Docker daemon is already configured with the NVIDIA Container
Toolkit as a runtime (`nvidia-container-runtime`), it's possible to get real
GPU access into a KIND node, since KIND nodes are themselves Docker
containers:

1. Set `nvidia` as Docker's **default** runtime on the host
   (`/etc/docker/daemon.json`: `"default-runtime": "nvidia"`) and restart
   Docker — KIND's own node containers don't take a `--gpus` flag, so this is
   the only way to hand them a GPU.
2. Add a `containerdConfigPatches` block to `kind-config.yaml` registering an
   `nvidia` `RuntimeClass` inside the KIND node's containerd, and install
   NVIDIA's `k8s-device-plugin` DaemonSet (not the full GPU Operator — it
   doesn't support running nested inside a KIND node) so `nvidia.com/gpu`
   becomes allocatable.

This repo does not script this path: it depends entirely on the host's
Docker daemon configuration, which this build session had no way to verify
against (see `docs/phase-notes/phase-0.md`), and a half-working GPU-in-KIND
setup is worse than a clearly CPU-only one. If you get it working, the real
`edge/manifests/vlm-deployment.yaml` and `ingest-deployment.yaml` (GPU
variant) should apply to a KIND cluster set up this way without changes.
