# Phase 2 — RAN/UE Simulation (UERANSIM)

## Status: Scaffolded, not yet run (see phase-0.md for why)

## What was built

- `ran/gnb-config.yaml`, `ran/ue-config.yaml`: adapted from UERANSIM's own
  `config/open5gs-gnb.yaml` / `config/open5gs-ue.yaml` samples for this lab's
  addressing and test subscriber.
- `ran/docker-compose.yml`: gNB and UE as separate `gradiant/ueransim`
  containers, both attached to the same `open5gscore` bridge network the
  core uses, so the gNB can reach the AMF's NGAP address and the UPF's GTP-U
  address directly (no SCTP-over-NAT complications), and the UE reaches the
  gNB's simulated radio link the same way. This matches the pattern used by
  the `herlesupreeth/docker_open5gs` reference deployment.
- `scripts/verify-pdu-session.sh`: the Phase 2 DoD check — confirms
  `uesimtun0` exists and that a ping through it succeeds.

## How to run this for real (on the actual host, after Phase 1 is up)

```bash
cd ran
docker compose --env-file ../.env up -d
docker logs -f ueransim-ue   # watch for "PDU Session Establishment is successful"
../scripts/verify-pdu-session.sh
```

## DoD (copy real output here once run on the target host)

- [ ] `nr-ue` log shows successful registration and PDU session establishment
- [ ] `uesimtun0` exists with an assigned IP inside `10.45.0.0/16`
- [ ] `ping -I uesimtun0 8.8.8.8` succeeds

## Known risks to watch for on first real run

- UERANSIM requires SCTP support in the kernel (`modprobe sctp`) on the
  Docker host — confirmed absent in this build session (see phase-0.md);
  must be present on the real host.
- `privileged: true` is used for both containers because UERANSIM needs raw
  socket + TUN access; if the host's container runtime restricts this,
  narrow it to the specific capabilities UERANSIM's docs list instead.
- The `edge` DNN session in `ue-config.yaml` will be rejected until it's
  provisioned in Phase 3 — expected, and does not block this phase's DoD.
