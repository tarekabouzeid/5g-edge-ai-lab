# Phase 3 — Local Breakout Configuration

## Status: Verified on the WSL2 host (minikube), 2026-09-24 — DoD met

## What was built

- `core/config/smf.yaml` / `core/config/upf.yaml`: a second DNN (`edge`,
  subnet `10.47.0.0/16`, TUN device `ogstun2`) alongside `internet`.
- `core/docker-compose.yml`'s UPF entrypoint only adds the iptables
  `MASQUERADE` rule for `INTERNET_UE_SUBNET`, deliberately leaving the `edge`
  subnet un-NAT'd — that's what makes this "local breakout" rather than just
  a second internet path.
- `edge/setup-minikube-breakout.sh` (`./lab.sh breakout up`, no sudo):
  minikube's node is a container on its own Docker network (`minikube`,
  `192.168.49.0/24`), so instead of routing through the host, the UPF
  container is attached to that network too, the minikube node gets
  `10.47.0.0/16 via <UPF>` as its return route, and the UE routes the node IP
  over its edge tunnel (picked by subnet — the uesimtunN ↔ DNN mapping
  changes between attaches). Runtime state only: re-run after restarting
  minikube, the UPF, or the UE (the lab portal re-applies the UE-side route
  itself).

## How to verify this for real (on the actual host)

```bash
./lab.sh core up && ./lab.sh ran up && ./lab.sh minikube up && ./lab.sh edge-apps up
./lab.sh breakout up
docker exec -it open5gs-upf tcpdump -i ogstun2 -n &
./scripts/demo-stream-from-ue.sh      # or start the camera from the lab portal
```

## DoD (real output, WSL2 host, 2026-09-24)

- [x] `tcpdump` on `ogstun2` shows the traffic with its **original** UE
      source address — `10.47.0.2 > 192.168.49.2.30554` for the whole
      stream — proving it was not masqueraded
- [ ] a parallel capture on the host's real uplink interface (e.g. `eth0`)
      shows **no** corresponding traffic leaving to the internet — proving
      it stayed local
- [x] the edge cluster actually receives and responds to the traffic: full
      TCP handshakes and the RTSP stream; mediamtx logs the publisher as
      `10.47.0.2`, while the internet-DNN path shows up NAT'd as `10.10.0.7`
      (see `docs/phase-notes/phase-7.md`)

## Since 2026-10-27: through Envoy

The breakout routing is unchanged, but the target on the node is now
Envoy Gateway (mutual TLS, `:30322` RTSPS / `:30443` HTTPS) instead of
mediamtx's own NodePort 30554, and `./lab.sh breakout up` also provisions
each phone's edge credentials (`docs/security.md`). The un-NAT'd property
still holds: Envoy's Service keeps the source address
(`externalTrafficPolicy: Local`) and passes it to mediamtx with the PROXY
protocol. Re-check the first DoD item with the new port — not yet re-run
on the host.

## History

The first design routed the edge DNN through the host to a natively
installed K3s cluster (`setup-local-breakout-route.sh`, needed sudo). It was
removed with the K3s path on 2026-09-25 (see phase-4.md); it's in git
history if ever needed.
