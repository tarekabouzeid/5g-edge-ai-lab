# Phase 3 — Local Breakout Configuration

## Status: Verified on the WSL2 host via the minikube variant, 2026-09-24 — DoD met

The K3s-oriented host-route design below (`setup-local-breakout-route.sh`,
needs sudo) is kept for bare-metal K3s. On the verified minikube path the
breakout is `edge/setup-minikube-breakout.sh` (`./lab.sh breakout up`, no
sudo): the UPF container is attached to the `minikube` Docker network, the
minikube node gets `10.47.0.0/16 via <UPF>`, and the UE routes the node IP
over its edge tunnel (picked by subnet — the uesimtunN ↔ DNN mapping changes
between attaches). Real output: `tcpdump -i ogstun2` on the UPF shows
`10.47.0.2 > 192.168.49.2.30554` for the whole stream, mediamtx logs the
publisher as `10.47.0.2`, and the internet-DNN path shows up NAT'd as
`10.10.0.7` instead (see `docs/phase-notes/phase-7.md`).

## What was built

- `core/config/smf.yaml` / `core/config/upf.yaml`: a second DNN (`edge`,
  subnet `10.47.0.0/16`, TUN device `ogstun2`) alongside `internet`.
- `core/docker-compose.yml`'s UPF entrypoint only adds the iptables
  `MASQUERADE` rule for `INTERNET_UE_SUBNET`, deliberately leaving the `edge`
  subnet un-NAT'd — that's what makes this "local breakout" rather than just
  a second internet path.
- `edge/setup-local-breakout-route.sh`: a host-side script adding the route
  and forwarding rules the host needs so K3s (running natively on the same
  host per `docs/architecture.md`) can actually reply to traffic sourced from
  `10.47.0.0/16`.

## How to verify this for real (on the actual host)

1. `scripts/provision-subscriber.sh` gives the test subscriber both the
   `internet` and the `edge` DNN session.
2. Bring up `ran/docker-compose.yml` (Phase 2) so the UE's edge tunnel (the
   uesimtunN with a `10.47.x.x` address) comes up.
3. `./edge/setup-local-breakout-route.sh`
4. Start a capture on the UPF's N6 side and send edge-DNN traffic:

```bash
docker exec -it open5gs-upf tcpdump -i ogstun2 -n &
docker exec ueransim-ue ping -I <edge uesimtunN> -c 5 <a K3s Service ClusterIP or NodePort host IP>
```

## DoD (copy real output here once run on the target host)

- [x] `tcpdump` on `ogstun2` shows the ICMP/TCP traffic with its **original**
      UE source address (`10.47.x.x`) — proving it was not masqueraded
- [ ] the same capture, or a parallel one on the host's real uplink interface
      (e.g. `eth0`), shows **no** corresponding traffic leaving to the
      internet — proving it stayed local
- [x] the edge-cluster target actually receives and responds to the traffic (minikube: full TCP handshakes and the RTSP stream)

## Known risks to watch for on first real run

- The exact route/forwarding rules in `setup-local-breakout-route.sh` assume
  K3s uses its default Flannel CNI and that NodePort/ClusterIP traffic
  reaching the host is enough to get a reply routed back out through the
  docker bridge — this has not been validated against a live K3s install.
  If the K3s CNI's own iptables/nftables rules (or a firewall like `ufw`)
  drop the return path, add a matching ACCEPT rule for `EDGE_UE_SUBNET` on
  whatever chain is dropping it (`iptables -L -v -n --line-numbers` after a
  failed test will show which chain incremented).
- If `docker0`'s default bridge is replaced by a custom bridge network name
  (as in `core/docker-compose.yml`, `open5gscore`), routes here are added by
  gateway IP rather than device name specifically so they don't depend on
  that bridge's internal Linux interface name.
