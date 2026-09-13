# Phase 5 — Video Ingestion Pipeline

## Status: Scaffolded, not yet run/built (see phase-0.md for why)

## What was built, and why GStreamer/OpenCV instead of DeepStream by default

PROJECT_PLAN.md Section 4 names NVIDIA DeepStream as the default choice, with
GStreamer + OpenCV as the fallback "if DeepStream install proves too fragile
on a single consumer GPU." DeepStream's install is tightly version-pinned to
a specific driver/CUDA/TensorRT/L4T combination, and this build session has
no way to verify the real host's driver/CUDA version against DeepStream's
compatibility matrix (see `docs/phase-notes/phase-0.md` — no GPU, no driver,
no way to check). Rather than hardcode a DeepStream container image tag that
has a real chance of being wrong for the actual hardware, the default here is
the fallback: a small FastAPI + OpenCV + YOLOv8n (ultralytics, CUDA-enabled
PyTorch) service. It still does real GPU inference and satisfies Phase 5's
DoD; DeepStream can be swapped in later as a drop-in replacement behind the
same Deployment/Service boundary once the real host's compatibility is
confirmed.

- `edge/ingest/app.py`, `requirements.txt`, `Dockerfile`: the ingestion
  service — connects to an RTSP source, runs YOLOv8n on every Nth frame,
  and (Phase 6) periodically forwards a frame to the VLM.
- `edge/manifests/gateway.yaml`: `bluenviron/mediamtx`, a lightweight RTSP
  server, as the actual "Ingress/Gateway Pod" the architecture diagram shows
  — this is what `scripts/stream-test-video.sh` pushes video into and what
  the ingest pod reads from.
- `edge/manifests/ingest-deployment.yaml`: the ingest Deployment/Service,
  requesting `nvidia.com/gpu: 1`.

## How to run this for real (on the actual host, after Phase 4)

```bash
docker build -t edge-ingest:local edge/ingest
docker save edge-ingest:local | sudo k3s ctr images import -
kubectl apply -f edge/manifests/gateway.yaml
kubectl apply -f edge/manifests/ingest-deployment.yaml
kubectl wait --for=condition=Ready pod -l app=edge-ingest --timeout=120s
./scripts/stream-test-video.sh           # synthetic test pattern, 60s
kubectl logs -l app=edge-ingest --tail=50
nvidia-smi dmon                          # watch GPU utilization rise
```

## DoD (copy real output here once run on the target host)

- [ ] `edge-ingest` pod logs show frames being read and detections logged
- [ ] `nvidia-smi dmon` on the host shows utilization rise during the stream

## Known risks to watch for on first real run

- `edge-ingest:local` + `imagePullPolicy: Never` assumes a single-node
  cluster where the image only needs to exist in that one node's containerd
  — correct for this lab's MVP scope, would need a registry for Phase 10's
  multi-node stretch goal.
- YOLOv8n's first run downloads/caches weights baked in at Docker build time
  (see the Dockerfile's `RUN python -c "... YOLO('yolov8n.pt')"` line) —
  if that step fails at build time (no network in the build environment),
  it will instead download on first inference, adding latency to the very
  first frame only.
