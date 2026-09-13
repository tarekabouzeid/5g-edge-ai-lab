# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A home-lab build of a full 5G edge-AI data path — simulated UE/RAN → real
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
./lab.sh all up           # core -> RAN -> K3s+GPU Operator -> edge apps -> monitoring
./lab.sh <core|ran|k3s|kind|edge-apps|monitoring> <up|down|status>
./lab.sh status
```

Per-phase scripts (also callable directly, and what `lab.sh` wraps):
`scripts/provision-subscriber.sh`, `scripts/verify-pdu-session.sh`,
`scripts/stream-test-video.sh`, `scripts/benchmark.py`,
`edge/setup-local-breakout-route.sh`, `edge/k3s-install.sh`,
`edge/install-gpu-operator.sh`, `monitoring/deploy.sh [--no-gpu]`,
`edge/kind/kind-up.sh` / `kind-down.sh`.

## What can't run in a typical Claude Code session

This repo was built and is largely maintained from sandboxed sessions with
**no Docker daemon, no GPU, and no SCTP kernel support** (documented in
`docs/phase-notes/phase-0.md`). Assume the same is true of your own session
unless you've confirmed otherwise (`docker version`, `nvidia-smi`). That
means:
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
| `edge/` | 3–6 | Local-breakout host routing, K3s + NVIDIA GPU Operator (real host), a KIND alternative (`edge/kind/`, CPU-only, no GPU), and the ingestion (`edge/ingest/`) + VLM K8s manifests |
| `monitoring/` | 8 | Prometheus + DCGM exporter + Grafana, deployed onto whichever K8s cluster (K3s or KIND) is current `kubectl` context |
| `scripts/` | 1,2,5,7,9 | One-shot operational scripts (provisioning, verification, streaming, benchmarking, version-checking) |

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
