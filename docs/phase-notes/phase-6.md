# Phase 6 — VLM Inference Service

## Status: In progress on real hardware (WSL2 host) — Phase 4/5 done, VLM
serving is mid-debug as of 2026-09-22 (see "Known risks" below); not yet
DoD-verified end to end

## What was built (current: llama.cpp, not vLLM — see "Known risks")

- `edge/manifests/vlm-deployment.yaml`: `ghcr.io/ggml-org/llama.cpp:server-cuda`
  serving a GGUF build of `Qwen2-VL-2B-Instruct` (`ggml-org/Qwen2-VL-2B-Instruct-GGUF:Q4_K_M`,
  downloaded via `-hf` on first start — both the model and its mmproj
  vision-projector file come from the same repo) — deliberately small
  (~2B params). This lab doesn't need SOTA caption accuracy, just a
  sensible scene description, and a small model leaves real headroom on
  the one 16GB GPU for the ingest pod's YOLO model to coexist without
  hitting Phase 11's GPU-sharing problem (both pods currently request a
  whole `nvidia.com/gpu: 1`, so only one can be scheduled at a time until
  Phase 11's time-slicing/MPS setup is done — remember to
  `kubectl scale deployment edge-ingest --replicas=0` before testing the
  VLM pod standalone, and scale it back to 1 afterward). Its
  `/v1/chat/completions` is OpenAI-compatible including `image_url`
  content parts, so `edge/ingest/app.py`'s VLM call needed no changes.
  Uses a `hostPath` volume for the model cache so weights survive pod
  restarts — on minikube's docker driver this path must exist **inside
  the minikube node**, not the WSL2 host: `minikube ssh -- sudo mkdir -p
  /opt/edge-lab/hf-cache`.
- `edge/ingest/app.py` already calls this service's
  `/v1/chat/completions` endpoint with a base64 JPEG frame every
  `VLM_SAMPLE_EVERY_N_FRAMES` frames (env-configurable), wiring Phase 5's
  output into Phase 6 as the plan requires.

## How to run this for real (on the actual host, after Phase 4)

```bash
minikube ssh -- sudo mkdir -p /opt/edge-lab/hf-cache
kubectl scale deployment edge-ingest --replicas=0   # free the GPU, see above
kubectl apply -f edge/manifests/vlm-deployment.yaml
kubectl wait --for=condition=Ready pod -l app=vlm --timeout=600s   # first pull + model load is slow
kubectl port-forward svc/vlm 8000:8000 &
curl http://localhost:8000/v1/models
```

## DoD (fill in once VLM startup is actually resolved — see below)

- [ ] `vlm` pod reaches Ready (model loaded)
- [ ] a sample frame POSTed to `/v1/chat/completions` returns a sensible
      caption/description (check `edge-ingest`'s logs for "VLM caption: ...")

## Known risks — real findings from this host (WSL2, RTX 5070 Ti), 2026-09-22

### Why this uses llama.cpp instead of vLLM

The original plan (and this manifest, until today) used
`vllm/vllm-openai:v0.29.0`. Confirmed on this host: **vLLM's engine startup
hangs indefinitely** — not a crash, not slow; genuinely stuck (blocked in
`futex_wait_queue_me` at the OS level, doesn't even respond to `SIGTERM`) —
immediately after it selects FlashAttention for Qwen2-VL's vision tower,
before the first forward pass completes. This survived every standard fix
tried, in this order:

1. **Fixed a real, separate bug first**: engine init originally crashed
   outright with `RuntimeError: UVA is not available` — a confirmed
   upstream WSL2 issue (vllm-project/vllm#43381, #47292, #47387). vLLM's
   V2 model runner allocates request state via a CUDA UVA (Unified Virtual
   Addressing) buffer, which needs pinned host memory; vLLM's CUDA
   platform reports none available under WSL2 unless explicitly opted in.
   Fix: `VLLM_WSL2_ENABLE_PIN_MEMORY=1` (needs WSL2 kernel >=4.19.121;
   this host's 5.15.167.4 easily qualifies). **This fix is real and worth
   keeping if vLLM is ever revisited** — it's a different bug from the
   hang below, and is genuinely solved by this one env var.
2. With that fixed, hit the actual hang described above. Tried, in order,
   none of which changed the outcome at all (identical hang, same log
   line every time — `Using FlashAttention version 2`):
   - `--enforce-eager` (rules out CUDA graph capture as the cause)
   - `VLLM_ATTENTION_BACKEND=TORCH_SDPA` (still selected FlashAttention
     for vit/vision-tower attention specifically — that override appears
     to only affect the main LLM's attention, not the vision encoder's)
   - `NCCL_P2P_DISABLE=1` + `NCCL_SHM_DISABLE=1` (standard fix for NCCL
     init hangs under virtualized GPUs — vLLM initializes a single-rank
     NCCL process group even for single-GPU inference; didn't help either)
3. **Ruled out the GPU passthrough itself**: a plain PyTorch CUDA matmul
   (`torch.randn(1000,1000).cuda() @ ...`) run in an ordinary pod on this
   same cluster completed instantly with a correct numeric result. The
   hang is specific to something in vLLM's own FlashAttention/vision-tower
   or multi-process path under WSL2's paravirtualized GPU passthrough, not
   a general "GPU doesn't work in containers" problem.

Given real GPU compute is confirmed working and the vLLM-specific cause
wasn't pinned down after a reasonably thorough sweep, switched to
llama.cpp's server instead — a stack already confirmed working with GPU
acceleration on this exact host from a prior, separate project. **This
migration is not yet itself DoD-verified** (the llama.cpp pod was still
pulling its (uncached, first-time) image when this session ended) — the
next session should pick up from `kubectl get pods -l app=vlm` and this
file's DoD checklist above.

### GPU-sharing (Phase 11) blocks testing ingest + VLM together

Both `edge-ingest` and `vlm` request a whole `nvidia.com/gpu: 1`, and this
host has exactly one GPU — only one of the two deployments can have a
`Running` pod at a time until Phase 11's time-slicing/MPS setup exists.
Scale the other one to 0 replicas before testing either standalone (see
the run commands above). This also means the *actual* Phase 7 end-to-end
test (video → ingest → VLM caption, both alive simultaneously) can't
happen until Phase 11 is done, regardless of whether the VLM startup
issue above is resolved.

### If revisiting vLLM later

Worth trying, not yet attempted: pinning to a different vLLM version (the
hang may be specific to v0.29.0's FlashAttention/vision-tower integration
rather than a fundamental WSL2 incompatibility), or filing/searching a
fresh upstream issue with the exact `futex_wait_queue_me` stack — none of
the existing UVA-related upstream issues (#43381/#47292/#47387) mention
this specific post-fix hang, so it may not yet be a known/tracked bug.
