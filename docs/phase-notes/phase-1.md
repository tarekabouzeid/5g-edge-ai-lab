# Phase 1 — 5G Core (Open5GS)

## Status: Run for real on a WSL2 host, 2026-09-20 — DoD met

## What was built

- `core/docker-compose.yml`: every Open5GS NF (NRF, SCP, AUSF, UDM, UDR, PCF,
  BSF, NSSF, AMF, SMF, UPF) as its own container from the `gradiant/open5gs`
  image, plus MongoDB and the WebUI, on one static-IP bridge network
  (`10.10.0.0/24`).
- `core/config/*.yaml`: one config per NF, adapted from the upstream Open5GS
  `main` branch templates (`configs/open5gs/*.yaml.in`) to this lab's
  addressing and two DNNs (`internet`, `edge` — see phase-3.md).
- Architecture choice: **SCP-mediated (indirect) SBI communication**, the
  current upstream-recommended default, rather than the older direct-NRF
  pattern from pre-2.6 tutorials. Every NF's `sbi.client` only points at the
  SCP; only the SCP itself talks to the NRF.
- `scripts/provision-subscriber.sh`: provisions the Phase 1 DoD test
  subscriber via `gradiant/open5gs-dbctl`, a one-shot container that
  packages upstream open5gs's own `misc/db/open5gs-dbctl` script, rather
  than a hand-written MongoDB insert, so the document schema can't drift
  from what this Open5GS version actually expects. (An earlier version of
  this script tried `docker exec`-ing into the `open5gs-webui` container
  and running that same script there — wrong: the webui image only
  contains the Node.js web UI, not the CLI script, confirmed against its
  own Dockerfile source. `docker run --rm --network open5gscore
  gradiant/open5gs-dbctl ...` is the correct invocation.)

## How to run this for real (on the actual host)

```bash
cd core
cp ../.env.example ../.env   # edit if you want different addressing
docker compose --env-file ../.env up -d
docker compose ps            # all services should show "running"/"healthy"
../scripts/provision-subscriber.sh
```

## DoD (real output, WSL2 host, 2026-09-20)

- [x] `docker compose ps` shows all 12 services running (after the two
  fixes below — `user: root` on `upf`, dropping the SCTP port publish on
  `amf` — both needed on this host to get there)
- [x] `provision-subscriber.sh` printed the real subscriber document (IMSI
  `999700000000001`, `internet` DNN session, K/OPC matching `.env`) —
  "If this printed a document (not null), Phase 1's subscriber-provisioning
  DoD is met."

## Known risks to watch for on first real run

- `gradiant/open5gs:2.8.0` is a community-maintained image, not an official
  Open5GS release artifact — if the tag is gone or the binary layout differs,
  pin a nearby tag from https://hub.docker.com/r/gradiant/open5gs/tags and
  adjust `OPEN5GS_IMAGE_TAG` in `.env`.
- The UPF's `entrypoint` tries an `iptables` NAT rule before exec'ing the
  daemon, but doesn't require it to succeed (`||`, not `&&`) — on GitHub's
  CI runners this rule fails outright (`iptables v1.8.7 (nf_tables): ...
  Permission denied (you must be root)`), and the daemon starts anyway with
  a warning logged. If the same happens on your real host, this alone
  doesn't block Phase 1/2; only Phase 2's internet-DNN ping check would
  fail. The edge DNN (Phase 3, the one this project actually needs) never
  depended on this rule.
- Opening the `ogstun` TUN device needs more than `NET_ADMIN`+`NET_RAW` in
  most container setups, so the UPF service runs `privileged: true` (matching
  what `ran/docker-compose.yml` already does for UERANSIM's TUN interface,
  for the same reason) — this is the right config for a normal Docker host,
  and is a reasonable default for a lab that already isn't security-hardened
  (PROJECT_PLAN.md Section 8). **However**, on GitHub-hosted Actions runners
  specifically, even `privileged: true` isn't enough — TUN device creation
  fails there with `ioctl() failed ... Operation not permitted` regardless,
  a runner-infrastructure sandboxing limitation CI cannot work around. CI's
  core-smoke-test job therefore excludes `open5gs-upf` from its "all NFs
  healthy" check (see `.github/workflows/ci.yml`'s comments) — every other
  NF, and subscriber provisioning, are still held to the full check.

  **Update, 2026-09-20 (real host, WSL2):** `privileged: true` alone was
  *not* enough on a real host either — but for a different, fixable reason
  than the CI limitation above. Same symptom (`ioctl() failed ...
  Operation not permitted` on `/dev/net/tun`), different cause: the
  `gradiant/open5gs` image's default entrypoint runs as a non-root user
  (uid 999, confirmed via `docker run --entrypoint sh gradiant/open5gs:2.8.0
  -c 'id; cat /proc/self/status | grep -i cap'` → `uid=999(open5gs)`,
  `CapEff: 0000000000000000`). Docker's `--privileged` only grants the full
  capability set to a **root** process — a non-root user gets nothing extra
  from it. Verified the fix directly: the same `docker run` with `--user
  root` gets `CapEff` populated and `ip tuntap add ... mode tun` succeeds.
  Fix applied in `core/docker-compose.yml`: added `user: root` to the `upf`
  service, alongside the existing `privileged: true` and
  `devices: [/dev/net/tun:/dev/net/tun]`. If you see this exact error on
  your own real host, check `docker exec open5gs-upf id` (or `docker run
  --entrypoint sh <image> -c id` if the container is crash-looping too fast
  to exec into) before assuming it's the same unfixable CI limitation
  described above — it very likely isn't.
- MongoDB has no auth configured — acceptable for a home lab per the
  project's non-goals (Section 8), not for anything internet-reachable.
- **AMF's host SCTP port publish (`38412:38412/sctp`) can break the
  container entirely on hosts whose kernel lacks the `xt_sctp` netfilter
  module** (confirmed on WSL2, 2026-09-20). Symptom is confusing: AMF
  crash-loops with `socket bind(2) [10.10.0.5]:7777 failed (99:Cannot
  assign requested address)` — a *TCP* SBI-port bind failure, nothing
  SCTP-looking in the error at all. Root cause, found by reproducing with a
  bare `docker run` using the same static IP and port mapping: Docker's
  DNAT rule for the published SCTP port fails at the iptables level
  (`iptables ... Extension sctp revision 0 not supported, missing kernel
  module?`), and that failure leaves the container's network attachment
  broken enough that it can't bind *any* of its own configured addresses,
  not just the SCTP one. This is unrelated to the base SCTP *protocol*
  support checked in `docs/phase-notes/phase-0.md` (that's compiled into
  WSL2's kernel and works fine) — this is a separate, more specific
  netfilter module for SCTP *NAT* specifically. Fix: removed the port
  publish from `core/docker-compose.yml`'s `amf` service entirely — it was
  never actually needed, since `ran/docker-compose.yml`'s gNB is itself a
  container on the same `open5gscore` bridge network and already reaches
  AMF directly by its static IP (see that file's own comment). Only add the
  publish back if something outside Docker needs to reach AMF's NGAP port
  directly, on a host confirmed to support SCTP NAT.
