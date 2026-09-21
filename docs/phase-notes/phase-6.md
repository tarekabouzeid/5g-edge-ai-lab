# Phase 6 — VLM Inference Service

## Status: Scaffolded, not yet run (see phase-0.md for why)

## What was built

- `edge/manifests/vlm-deployment.yaml`: `vllm/vllm-openai` serving
  `Qwen/Qwen2-VL-2B-Instruct` — deliberately small (~2B params). This lab
  doesn't need SOTA caption accuracy, just a sensible scene description,
  and a small model leaves real headroom on the one 16GB GPU for the
  ingest pod's YOLO model to coexist without hitting Phase 11's GPU-sharing
  problem. Swap `VLM_MODEL` in `.env` (and this manifest's `args`, which
  aren't env-substituted) for a larger Qwen VL model if you want more
  accuracy and have done the time-slicing/MPS setup in
  `docs/phase-notes/phase-11.md`. Uses a `hostPath` volume for the Hugging
  Face cache so model weights survive pod restarts.
- `edge/ingest/app.py` already calls this service's
  `/v1/chat/completions` endpoint with a base64 JPEG frame every
  `VLM_SAMPLE_EVERY_N_FRAMES` frames (env-configurable), wiring Phase 5's
  output into Phase 6 as the plan requires.

## How to run this for real (on the actual host, after Phase 4)

```bash
sudo mkdir -p /opt/edge-lab/hf-cache
kubectl apply -f edge/manifests/vlm-deployment.yaml
kubectl wait --for=condition=Ready pod -l app=vlm --timeout=600s   # first pull + model load is slow
kubectl port-forward svc/vlm 8000:8000 &
curl http://localhost:8000/v1/models
```

## DoD (copy real output here once run on the target host)

- [ ] `vlm` pod reaches Ready (model loaded)
- [ ] a sample frame POSTed to `/v1/chat/completions` returns a sensible
      caption/description (check `edge-ingest`'s logs for "VLM caption: ...")

## Known risks to watch for on first real run

- `Qwen/Qwen2-VL-2B-Instruct` in fp16/bf16 plus KV cache at
  `--max-model-len=4096` and `--gpu-memory-utilization=0.4` should fit
  easily in 16GB alongside the ingest pod's small YOLOv8n model, but this
  has not been measured on the real GPU — if it OOMs, lower
  `--gpu-memory-utilization` further, lower `--max-model-len`, or switch to
  an AWQ/GPTQ-quantized build of the same model.
- First pod start downloads ~4-5GB of weights from Hugging Face — slow on a
  poor connection, and will need `HF_TOKEN` set as a Secret/env var if the
  model repo ever requires authentication (it does not, as of the version
  pinned in PROJECT_PLAN.md, but upstream repos can change gating).
