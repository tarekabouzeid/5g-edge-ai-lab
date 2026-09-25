# Phase 6 — VLM Inference Service

## Status: Verified on the WSL2 host (minikube), 2026-09-24 — DoD met (llama.cpp backend, Qwen2-VL-2B)

**2026-09-25: model switched to Gemma 4 E4B-it and llama.cpp bumped to
b11151 — not yet re-verified on the host.** Re-run the DoD below (with a
real image, not just text — see "Gemma 4 on Blackwell" under Known risks)
before ticking it again for Gemma.

## What was built (current: llama.cpp, not vLLM — see "Known risks")

- `edge/manifests/vlm-deployment.yaml`: `ghcr.io/ggml-org/llama.cpp:server-cuda-b11151`
  (pinned build) serving Google's Gemma 4 E4B-it (`ggml-org/gemma-4-E4B-it-GGUF:Q8_0`,
  downloaded via `-hf` on first start — both the model and its mmproj
  vision-projector file come from the same repo). Apache 2.0, ~4.5B
  effective params (8B total with per-layer embeddings). **Why Q8_0:**
  ggml-org's repo ships only Q4_0 (~4.6 GB) and Q8_0 (~8 GB) — no Q4_K_M,
  which is `-hf`'s default, so the quant must be named explicitly — and
  Q8_0 fits the 16 GB card with plenty left, so there's no reason to
  give up quality. `--reasoning off` stops Gemma 4 from spending the
  caption's small `max_tokens` budget on a thinking channel;
  `--ctx-size 8192` leaves room for one image's tokens plus prompt and
  answer. Replaced Qwen2-VL-2B-Instruct (2026-09-25) for a stronger
  model under a standard open-source license; this lab still doesn't need
  SOTA caption accuracy, just sensible scene descriptions and reliable
  answers to the portal's alert-rule questions. It is the only GPU consumer (edge-ingest
  runs YOLOv8n on CPU) and uses the `Recreate` rollout strategy, since a
  rolling update's surge pod can't schedule next to the old one on a single
  GPU. `--metrics` exposes tokens/s for Grafana. Its
  `/v1/chat/completions` is OpenAI-compatible including `image_url`
  content parts, so `edge/ingest/app.py`'s VLM call needed no changes.
  Uses a `hostPath` volume for the model cache so weights survive pod
  restarts — on minikube's docker driver this path must exist **inside
  the minikube node**, not the WSL2 host: `minikube ssh -- sudo mkdir -p
  /opt/edge-lab/hf-cache`.
- `edge/ingest/app.py` calls this service's `/v1/chat/completions` with a
  base64 JPEG frame every `VLM_INTERVAL_SECONDS` seconds (default 4) for
  scene descriptions, and again for the lab portal's "Ask the camera" and
  AI-question alert rules (`POST /api/ask` on edge-ingest).

## How to run this for real (on the actual host, after Phase 4)

```bash
./lab.sh edge-apps up        # creates the model cache dir in the node, applies gateway/ingest/vlm
# or by hand:
minikube ssh -- sudo mkdir -p /opt/edge-lab/hf-cache
kubectl apply -f edge/manifests/vlm-deployment.yaml
kubectl wait --for=condition=Ready pod -l app=vlm --timeout=600s   # first pull + model load is slow
kubectl port-forward svc/vlm 8000:8000 &
curl http://localhost:8000/v1/models
```

## DoD — verified 2026-09-24 (llama.cpp backend, Qwen2-VL-2B; re-verify for Gemma 4)

- [x] `vlm` pod reaches Ready (model loaded; ~6s once the hostPath cache is warm)
- [x] a sample frame POSTed to `/v1/chat/completions` returns a sensible
      caption/description — 200 in 3.2s, ~160 tok/s generation on the GPU;
      `edge-ingest` logs `VLM caption: ...` during the Phase 7 run

The GPU-sharing note below is resolved by design: `edge-ingest` no longer
requests a GPU (YOLOv8n on CPU), so `vlm` is the only GPU consumer. Warm
answers take ~0.15–0.7 s; ~230 tokens/s generation.

## Known risks — real findings from this host (WSL2, RTX 5070 Ti), 2026-09-22

### Gemma 4 on Blackwell: test with a real image (2026-09-25, not yet hit here)

Upstream [llama.cpp#21402](https://github.com/ggml-org/llama.cpp/issues/21402)
reports Gemma 4's mmproj aborting (`SIGABRT` in `clip_model_loader::load_tensors`)
on CUDA with an RTX 5090 (Blackwell, same generation as this host's
RTX 5070 Ti) on build b8650 — for the 31B and 26B-A4B variants; text-only
worked. It was closed as stale, not fixed. This lab uses E4B on the much
newer b11151, so it may not apply, but a text-only `/v1/chat/completions`
check would not catch it: the DoD's sample-frame POST is the real test.
If it does crash, the fallback is NVIDIA's Nemotron Nano 12B v2 VL
(mainline llama.cpp support since PR #19547), which needs its own
thinking toggle and possibly a local GGUF conversion.

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

### (Resolved) GPU-sharing (Phase 11) blocked testing ingest + VLM together

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
