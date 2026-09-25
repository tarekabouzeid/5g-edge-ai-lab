# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**5G Edge AI Lab** (use exactly this name in docs and UI): a
home-lab build of a full 5G edge-AI data path — simulated UE/RAN → real
Open5GS core → real K3s edge cluster → real GPU video/VLM inference —
implemented as infrastructure-as-code (Docker Compose, Kubernetes manifests,
shell scripts), not application code. There is no compiler/test-suite in the
usual sense; "correctness" here means configs that actually bring up the
stack, which is why `docs/phase-notes/phase-N.md` and `.github/workflows/
ci.yml` carry real DoD (Definition of Done) verification, not just intent.
Read `PROJECT_PLAN.md` first for the full brief and phase breakdown.

## Commands

Validate everything without needing Docker/a GPU/a cluster (this is what CI
runs, and the fastest way to sanity-check an edit before pushing):

```bash
# YAML syntax across the whole repo
python3 -c "import yaml, glob; [list(yaml.safe_load_all(open(f))) for f in glob.glob('**/*.yml', recursive=True) + glob.glob('**/*.yaml', recursive=True)]"

# Shell scripts (matches CI's threshold exactly)
shellcheck -S warning $(find . -name '*.sh' -not -path './.git/*')

# Compose files resolve (needs a real .env, not just .env.example)
cp .env.example .env && docker compose -f core/docker-compose.yml --env-file .env config -q && docker compose -f ran/docker-compose.yml --env-file .env config -q

# Kubernetes manifests against the real schema
curl -sSL https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz | tar xz kubeconform
./kubeconform -strict -summary edge/manifests/*.yaml edge/gpu-operator/*.yaml edge/kind/ingest-deployment.kind.yaml monitoring/manifests/*.yaml

# Dockerfile lint (install hadolint first if not present)
hadolint edge/ingest/Dockerfile
```

Check whether pinned versions have drifted from upstream:

```bash
./scripts/check-latest-versions.sh
```

Bring up / tear down the stack (requires the real host — see "What can't run
here" below):

```bash
./lab.sh                 # prints the full command list
./lab.sh all up           # core -> RAN -> minikube+GPU -> edge apps -> breakout -> monitoring -> portal
./lab.sh all up --k3s     # same, but K3s + GPU Operator (bare-metal Linux; breakout needs sudo)
./lab.sh <core|ran|minikube|k3s|kind|edge-apps|breakout|monitoring|portal> <up|down|...>
./lab.sh status
./lab.sh all down         # non-destructive
```

Per-phase scripts (also callable directly, and what `lab.sh` wraps):
`scripts/provision-subscriber.sh` (both DNN sessions, idempotent),
`scripts/verify-pdu-session.sh`, `edge/minikube-up.sh`,
`edge/setup-minikube-breakout.sh`, `monitoring/deploy.sh [--no-gpu]`,
`scripts/fetch-demo-media.sh`, `scripts/demo-stream-from-ue.sh`,
`scripts/stream-test-video.sh`,
`scripts/host-gpu-exporter.py`; K3s path: `edge/k3s-install.sh`,
`edge/install-gpu-operator.sh`, `edge/setup-local-breakout-route.sh`;
no-GPU dev path: `edge/kind/kind-up.sh` / `kind-down.sh`.

The verified path (WSL2 + NVIDIA GPU) is **minikube**: the whole lab comes up
with `./lab.sh all up` and **needs no sudo** once the NVIDIA Container Toolkit
is installed. UE tunnels (`uesimtunN`) must always be picked by subnet
(`10.45.x` internet, `10.47.x` edge) — the name ↔ DNN mapping flips between
attaches.

## What can't run in a typical Claude Code session

This repo was built and is largely maintained from sandboxed sessions with
**no Docker daemon, no GPU, and no SCTP kernel support** (documented in
`docs/phase-notes/phase-0.md`). Don't assume that's true by default, though
— **check first**, every session:

```bash
docker version                        # daemon reachable, not just the client?
nvidia-smi                            # real GPU driver?
grep -i sctp /proc/net/protocols      # SCTP built-in or loaded? (lsmod alone
                                       # misses kernels where it's compiled in)
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
```

A session running directly on the user's own machine (including a WSL2
Ubuntu host, not just bare-metal/VM Linux) can have all of the above
genuinely working — this has been confirmed for real on a WSL2 host with an
NVIDIA GPU (see `docs/phase-notes/phase-0.md`'s 2026-09-20 update and
`docs/phase-notes/phase-4.md`; none of the fixes documented there are tied
to any specific GPU model). In that case Phases 1, 2, and 4 can
actually be brought up and DoD-verified from inside the session, not just
lint-checked. Two things stay true even then:
- **No interactive `sudo`.** This session's shell has no TTY to answer a
  password prompt — `sudo` here fails with "a password is required, a
  terminal is required." Anything needing `sudo` (the NVIDIA Container
  Toolkit install; on the K3s path also K3s install, host routing,
  `mount --make-rshared`, GPU Operator's helm install) has to be
  handed to the user as an exact command to run themselves, then you read
  back the output they paste.
- **WSL2 specifically has its own gotchas beyond stock Ubuntu** — the
  NVIDIA Container Toolkit isn't preinstalled in the distro even when the
  Windows-side driver and `nvidia-smi` already work, GPU Operator's Node
  Feature Discovery can never detect the GPU (WSL2 exposes it as PCI vendor
  `1414`/Microsoft, never `10de`/NVIDIA), and the root filesystem's mount
  propagation defaults to `private` when the GPU Operator's toolkit needs
  `shared`. All three are documented with exact fixes in
  `docs/phase-notes/phase-4.md`'s "Known risks" section and the README's
  "Running on WSL2" section — check there before re-diagnosing from
  scratch. `EDGE_NODE_IP` in `.env` also needs a different answer on WSL2
  than the `.env.example` comment's default framing suggests (WSL2's own
  IP via `hostname -I`, not the Windows host's LAN IP) — see
  `.env.example`'s comment for that variable.

Where none of the above is confirmed working, treat the session as the
original sandboxed build environment:
- You cannot actually bring up `core/` or `ran/` or run `lab.sh` yourself —
  validate with the read-only commands above instead, and let CI (or the
  user, on the real host) do the real bring-up.
- Config correctness here has repeatedly needed a *real* bring-up to catch
  bugs that look fine on paper (wrong log paths, wrong capability grants,
  wrong image assumptions) — see the commit history and `docs/phase-notes/
  phase-1.md`'s "Known risks" section for concrete examples. Don't assume a
  change is correct just because it parses; say so explicitly if you can't
  verify it end-to-end.
- If you need to check something against a live GitHub Actions run, the
  `gh`/GitHub MCP tools' job-log retrieval is unreliable for very large or
  GPU-image-build jobs (log API 404s, signed blob URLs are proxy-blocked).
  When that happens, root-cause from the image/tool's actual upstream
  source (Dockerfile, script) rather than guessing blindly — that's how
  most of the real bugs in this repo's history were actually found.

## Architecture

Five layers, each its own top-level directory, matching the phases in
`PROJECT_PLAN.md`:

| Dir | Phase | Layer |
|---|---|---|
| `core/` | 1 | Open5GS 5G core — one container per network function (see Glossary in README), all on one static-IP Docker bridge (`open5gscore`, `10.10.0.0/24`) |
| `ran/` | 2 | UERANSIM gNB + UE — simulated radio, real NAS/NGAP/GTP-U, joins the same bridge network |
| `edge/` | 3–6 | minikube + GPU bring-up (`minikube-up.sh`, the verified path) and its no-sudo breakout (`setup-minikube-breakout.sh`); K3s + GPU Operator and host-route breakout (bare-metal alternative); KIND (`edge/kind/`, CPU-only); the ingestion image (`edge/ingest/`: RTSP → YOLOv8n on CPU → VLM, plus the API the portal uses) and the gateway/ingest/VLM manifests (VLM = llama.cpp + Qwen2-VL-2B, the only GPU consumer) |
| `monitoring/` | 8 | Prometheus + DCGM exporter + Grafana, deployed onto whichever K8s cluster (K3s or KIND) is current `kubectl` context |
| `portal/` | 7 | Lab portal (`./lab.sh portal up`, http://localhost:8090): FastAPI controller on the host network with the Docker socket — drives the UE via `nr-cli`/`docker exec`, parses NF logs into the attach timeline, hosts the emulated central-cloud WAN relay, evaluates alert rules (`portal/rules.py`: zone/count/ask-the-VLM) against the ingest service's `/api/state`/`/api/ask`/`/frame.jpg` — plus the single-screen mission-control UI. Binds 127.0.0.1 only. See `docs/demo.md` |
| `scripts/` | 1,2,5,7,8 | One-shot operational scripts (provisioning, verification, streaming, sample clips, GPU exporter, version-checking) |

`docs/architecture.md` has the full data-path diagram and the static IP
addressing table (every NF's IP is fixed and referenced by both compose
files and the `core/config/*.yaml` files — changing one means changing all).
`docs/what-is-simulated.md` states precisely what's real vs. simulated;
don't blur that line when describing this project.

**Two DNNs, deliberately**: `core/config/smf.yaml` and `upf.yaml` define an
`internet` DNN (NAT'd, exists only for a trivial ping-test DoD) and an
`edge` DNN (deliberately *not* NAT'd, so packets keep the real UE source
address all the way to the K3s ingress — this is the local-breakout
property the whole project is actually about). Don't "fix" the edge DNN's
missing NAT rule; that's the point.

**Version pinning convention**: every image/package tag lives in
`.env.example` (compose-consumed) or is hardcoded in the relevant K8s
manifest (kubectl doesn't do env substitution), always as an exact pinned
version, never `:latest`. `scripts/check-latest-versions.sh` is the
one-command way to check for drift — update it when you add a new pinned
dependency so drift-checking stays complete.

**CI (`​.github/workflows/ci.yml`)** runs two jobs on every push: `lint`
(everything in the Commands section above) and `core-smoke-test` (a real
`docker compose up` of `core/`, then subscriber provisioning — this is
Phase 1's actual DoD, running for real on GitHub-hosted runners). UPF is
deliberately excluded from that job's health check: GitHub's runners refuse
TUN device creation even in a privileged container, which is a runner
limitation, not a config bug (see `docs/phase-notes/phase-1.md`). Building
the GPU/CUDA `edge/ingest` image and the KIND smoke test are
`workflow_dispatch`-only (manual) — that image needs a real GPU to mean
anything and routinely exceeded standard runners' disk; validate it on the
real GPU host instead (`docs/phase-notes/phase-5.md`).

**Per-phase notes** (`docs/phase-notes/phase-N.md`) are not changelog
filler — each one has a DoD checklist, exact run commands, and a "Known
risks" section documenting real failures already hit and fixed (or
deliberately not fixed, with why). Read the relevant one before touching
config for that phase; update it when you find a new risk or fix one.
