# Phase 2 — RAN/UE Simulation (UERANSIM)

## Status: Run for real on a WSL2 host, 2026-09-20 — full DoD passes,
continuously, with `ran/rls-watchdog.sh` running (see "Known risks" for
why that script exists — an upstream UERANSIM bug, not a config issue in
this repo)

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
./rls-watchdog.sh &          # keep it running alongside — see "Known risks"
```

## DoD (real output, WSL2 host, 2026-09-20)

- [x] `nr-ue` log shows successful registration and PDU session
  establishment — `Initial Registration is successful`, then
  `PDU Session establishment is successful PSI[1]`,
  `TUN interface[uesimtun0, ...] is up`
- [x] `uesimtun0` exists with an assigned IP inside `10.45.0.0/16`
- [x] `ping -I uesimtun0 8.8.8.8` succeeds — confirmed via
  `scripts/verify-pdu-session.sh`'s own final output:
  ```
  PING 8.8.8.8 (8.8.8.8) from 10.45.0.5 uesimtun0: 56(84) bytes of data.
  64 bytes from 8.8.8.8: icmp_seq=1 ttl=114 time=4.76 ms
  64 bytes from 8.8.8.8: icmp_seq=2 ttl=114 time=3.98 ms
  64 bytes from 8.8.8.8: icmp_seq=3 ttl=114 time=4.04 ms
  --- 8.8.8.8 ping statistics ---
  3 packets transmitted, 3 received, 0% packet loss, time 1998ms

  PASS: UE registered, PDU session for 'internet' is up, and traffic
  routes out through the tunnel. Phase 2 DoD met.
  ```
  This only holds up *continuously* with `ran/rls-watchdog.sh` running
  alongside — without it, the tunnel goes down again within roughly
  10–30s of any given successful window, per the upstream bug below.

## Known risks to watch for on first real run

- UERANSIM requires SCTP support in the kernel (`modprobe sctp`) on the
  Docker host — confirmed absent in this build session (see phase-0.md);
  must be present on the real host. (Turned out fine on WSL2 — it's
  compiled in, not a loadable module; see phase-0.md's 2026-09-20 update.)
- `privileged: true` is used for both containers because UERANSIM needs raw
  socket + TUN access; if the host's container runtime restricts this,
  narrow it to the specific capabilities UERANSIM's docs list instead.
- The `edge` DNN session in `ue-config.yaml` will be rejected until it's
  provisioned in Phase 3 — expected, and does not block this phase's DoD.
  **Update, 2026-09-20:** confirmed this rejection isn't silent — the
  unprovisioned `edge` session's `PDU Session Establishment Request` never
  gets any response at all (not even an explicit reject) and retransmits
  forever on its T3580 timer (`Retransmitting PDU Session Establishment
  Request due to T3580 expiry`, every ~20s, indefinitely). This alone does
  **not** explain the ping failure below — isolated testing with only the
  `internet` session requested still hit the same radio-link instability —
  but it's real console noise and worth fixing anyway: either provision
  `edge` before running Phase 2 (WebUI: Subscriber → `999700000000001` →
  add session → DNN `edge`, slice sst 1), or temporarily drop the `edge`
  entry from `ue-config.yaml`'s `sessions:` list until Phase 3.
- **`gradiant/ueransim`'s baked-in `/entrypoint.sh` doesn't accept the
  `nr-gnb -c <file>` / `nr-ue -c <file>` invocation this project's compose
  file uses.** It only understands a literal first argument of `gnb` or
  `ue` (a "component selector"), and even then only envsubst's its own
  baked-in `/etc/ueransim/{gnb,ue}.yaml` templates — no way to point it at
  this project's own config files. Symptom: both containers crash-loop
  immediately with `unknown component -c is not a component (gnb or ue)`
  / `-c: command not found` (confirmed via `docker run --entrypoint cat
  gradiant/ueransim:3.3.0 /entrypoint.sh` to read the actual script). Fix
  applied in `ran/docker-compose.yml`: `entrypoint: []` on both services,
  bypassing the wrapper so `command: nr-gnb -c ...` / `nr-ue -c ...` runs
  the real binaries directly (both are plain executables on `PATH` that
  support `-c` exactly as expected — confirmed with `docker run
  --entrypoint nr-gnb gradiant/ueransim:3.3.0 --help`).
- **Root-caused and worked around, 2026-09-20: UERANSIM's own RLS
  (Radio Link Simulation — the UDP stand-in for the real air interface)
  periodically stalls, and gNB/UE sometimes never recover from the
  resulting reselection.** This is a genuine **upstream UERANSIM defect**,
  not a bug in this repo's config — confirmed by extensive isolation
  testing:
  - Reproduces identically on **two UERANSIM versions** (3.2.8 and 3.3.0,
    tested with matching isolated gNB/UE container pairs), ruling out a
    single-release regression.
  - **Ruled out host networking**: raw `ping` between the gNB/UE
    containers' static IPs is 0% loss, sub-ms RTT (same-host bridge); a
    from-scratch raw-UDP send/receive test (200 packets, no UERANSIM
    involved) was 100% reliable too.
  - **Ruled out host load**: 28 cores, load average ~1.7 (essentially
    idle) at the time; the container's own cgroup shows
    `nr_throttled 0`/`throttled_usec 0` (no CPU throttling).
  - **Packet capture on the gNB↔UE RLS UDP link (port 4997)** shows the
    exact mechanism: heartbeats every ~1s for a couple of beats, then a
    clean, silent ~8-second gap (heartbeat threshold in UERANSIM's own
    source is 2000ms — `src/ue/rls/udp_task.cpp` /
    `src/gnb/rls/udp_task.cpp` — so an 8s gap reliably trips "signal
    lost"), repeating roughly every 10-25s regardless of whether the UE is
    idle or under continuous ping traffic (so it is **not**
    inactivity-triggered).
  - `strace -f -p 1` on the UE process during a gap shows the RLS thread's
    own socket-poll loop (`pselect6`, 200ms timeout) running
    uninterrupted the whole time — the stall is downstream of the socket
    layer, in UERANSIM's own internal message handling, not a missed
    packet.
  - The AMF-context-loss half of the symptom
    (`AMF selection for UE[N] failed. Could not find a suitable AMF` /
    `AMF context not found with id: 0`, `Uplink data failure, PDU session
    not found`, `nr-cli <gnb> -e ue-list` accumulating ghost UE entries
    with `amf-ngap-id: -1`) is a known, currently-unresolved, **open**
    upstream issue:
    [aligungr/UERANSIM#757](https://github.com/aligungr/UERANSIM/issues/757)
    ("UE Context Release Causes Missing AMF Context and Paging Errors") —
    no fix or workaround posted there as of 2026-09-20.
  - Data plane forwarding **does work correctly** immediately after every
    fresh UE attach (verified repeatedly: a `ping -I uesimtun0` run in the
    first couple of seconds after registration gets real replies), and
    only degrades after the first stall — so this is a stability/recovery
    bug, not a fundamentally broken data path.

  **Workaround: `ran/rls-watchdog.sh`.** Since the tunnel is genuinely
  usable right after each fresh attach, a small supervisor script pings
  through `uesimtun0` every few seconds and, on failure, restarts **both**
  `ueransim-gnb` and `ueransim-ue` (restarting the UE alone isn't enough —
  the gNB's own ghost-UE bookkeeping degrades over repeated churn too,
  confirmed by `nr-cli ... ue-list` accumulating stale entries; a fresh UE
  attach against an already-degraded gNB often can't even find a cell).
  Run it alongside the RAN (`./ran/rls-watchdog.sh &`) to keep the data
  path continuously available. With it running, `scripts/verify-pdu-session.sh`
  passes reliably (see the DoD section above for real output) — without
  it, expect the tunnel to go down again within ~10-30s of any given
  success.
  Watch for one script bug that cost real debugging time and is worth
  remembering: `set -o pipefail` + `cmd_that_can_exit_nonzero | grep -q
  pattern` inverts the check whenever `cmd` itself exits non-zero (as
  `ping` does on packet loss) even if `grep` matches — pipefail promotes
  the pipeline's exit status to `cmd`'s failure regardless of what grep
  found. Fixed by capturing output into a variable first
  (`OUT=$(cmd) || true; grep -q pattern <<<"$OUT"`) rather than piping
  directly.
