# Phase 0 — Environment Prep

## Status: BLOCKED for DoD verification in the current build environment

This repository was scaffolded from a Claude Code **cloud/container session**,
not from the target home-lab host. Per the project plan's own rule
("if a DoD check fails and the cause is a hardware/driver/OS-level blocker
outside the repo's control ... stop and clearly report the blocker"), this is
reported explicitly rather than worked around.

### What the build container actually has

Checked directly in this session:

```
$ which docker
/usr/bin/docker
$ docker version
Client: Docker Engine - Community, 29.3.1  (client only)
$ docker run --rm --gpus all nvidia/cuda:12.x-base nvidia-smi
failed to connect to the docker API at unix:///var/run/docker.sock:
  connect: no such file or directory
$ nvidia-smi
bash: nvidia-smi: command not found
$ lsmod | grep sctp
(nothing — SCTP kernel module not loaded)
```

- **No Docker daemon** — only the client CLI is present, so nothing here can
  actually be brought up (Open5GS, UERANSIM, or K3s).
- **No NVIDIA driver / GPU** — this is a generic cloud VM, not the
  NVIDIA-GPU host described in the plan.
- **No SCTP support confirmed** — required for the AMF↔gNB N2/NGAP interface.
- No privileged/root container runtime for TUN device creation.

None of this is a code problem — it's the expected difference between a
scaffolding/authoring environment and the real target machine (bare-metal or
VM Ubuntu 22.04/24.04 with an NVIDIA GPU, Docker, and the NVIDIA driver
stack installed per Section 6 of `PROJECT_PLAN.md`).

### What this means for how the repo was built

Every phase's infrastructure-as-code (Docker Compose files, Open5GS NF
configs, UERANSIM configs, K3s bootstrap script, Kubernetes manifests,
monitoring config) has been authored and committed based on
current upstream documentation and source (Open5GS `main` branch config
templates, UERANSIM `master` sample configs, NVIDIA GPU Operator docs), but
**none of it has been executed or DoD-verified from this session**, because
the tools to do so (a working Docker daemon, a GPU, SCTP, root) are not
present here.

### What is still true and unblocked

- The repository structure, compose files, NF configs, RAN configs, K3s
  manifests, and scripts are real, complete, and ready to run — not
  placeholders.
- Nothing about the architecture needed to change to work around this; the
  scaffold assumes the real host described in the plan.

### Action needed from the operator

Run this repo's setup on the actual home-lab host and capture real DoD output
for each phase. Suggested first step:

```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
```

Once both succeed on the real host, Phase 0's DoD is met and Phase 1
(`core/docker-compose.yml`) can be brought up and verified for real. Please
paste back the actual command output (or open an issue / comment) for each
phase's DoD as you run it — later phases in this repo intentionally have not
been marked "done," only "scaffolded," until that happens.

### Update, 2026-09-20: DoD met on a WSL2 host

Phase 0's DoD was actually satisfied on a WSL2 Ubuntu 24.04 host with an
NVIDIA GPU (this run happened to use an RTX 5070 Ti, but nothing below is
specific to that card — it applies to any NVIDIA GPU passed through to
WSL2) — but a **vanilla WSL2 install is not identical to bare-metal
Ubuntu**, and needed one extra step this file's DoD commands don't mention:
`nvidia-smi` worked immediately (WSL2's own GPU paravirtualization), but
`docker run --gpus all ...` did not until the NVIDIA Container Toolkit was
installed *inside* the WSL distro itself (`nvidia-ctk`/CDI generation) —
the Windows-side driver alone doesn't wire that up. See the README's
"Running on WSL2" section (and `docs/phase-notes/phase-4.md`'s history
section for why the edge cluster ended up on minikube). SCTP,
despite this file's original finding, is fine on WSL2 — it's compiled into
the kernel already, no module to load.
