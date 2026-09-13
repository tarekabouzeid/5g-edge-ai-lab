# Phase 1 — 5G Core (Open5GS)

## Status: Scaffolded, not yet run (see phase-0.md for why)

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
  subscriber via `open5gs-dbctl` (shipped in the WebUI image) rather than a
  hand-written MongoDB insert, so the document schema can't drift from what
  this Open5GS version actually expects.

## How to run this for real (on the actual host)

```bash
cd core
cp ../.env.example ../.env   # edit if you want different addressing
docker compose --env-file ../.env up -d
docker compose ps            # all services should show "running"/"healthy"
../scripts/provision-subscriber.sh
```

## DoD (copy real output here once run on the target host)

- [ ] `docker compose ps` shows all 12 services running
- [ ] `provision-subscriber.sh` prints the subscriber document (not null)

## Known risks to watch for on first real run

- `gradiant/open5gs:2.8.0` is a community-maintained image, not an official
  Open5GS release artifact — if the tag is gone or the binary layout differs,
  pin a nearby tag from https://hub.docker.com/r/gradiant/open5gs/tags and
  adjust `OPEN5GS_IMAGE_TAG` in `.env`.
- The UPF's `entrypoint` adds an `iptables` NAT rule before exec'ing the
  daemon; this assumes `iptables` is present in the image. If it isn't,
  install it via a custom image layer, or move the rule to a host-side
  `iptables` command targeting the UPF container's network namespace instead.
- MongoDB has no auth configured — acceptable for a home lab per the
  project's non-goals (Section 8), not for anything internet-reachable.
