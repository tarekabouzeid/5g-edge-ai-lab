# Phase 7 — End-to-End Integration

## Status: DoD verified on the WSL2 host (minikube, RTX 5070 Ti), 2026-09-24

### Verified run (minikube docker driver — use this instead of steps 2/4's EDGE_NODE_IP)

On minikube the NodePort lives on the node container (`minikube ip`, e.g.
192.168.49.2), not the WSL2 host IP, and the host route in
`setup-local-breakout-route.sh` needs sudo. `edge/setup-minikube-breakout.sh`
replaces steps 2 and Phase 3's host route with no sudo: it attaches the UPF
to the `minikube` docker network, adds `10.47.0.0/16 via <UPF>` inside the
node, and routes the node IP via `uesimtun1` in the UE. Re-run it after any
minikube/UPF/UE restart.

Single-GPU layout: only `vlm` (llama.cpp + Qwen2-VL-2B GGUF) requests
`nvidia.com/gpu`; `edge-ingest` runs YOLOv8n on CPU, so both run together
without Phase 11's time-slicing.

```bash
./edge/setup-minikube-breakout.sh
docker exec ueransim-ue sh -c 'apt-get update -qq && apt-get install -y -qq ffmpeg'  # once per UE container
docker exec -d ueransim-ue sh -c 'ffmpeg -nostdin -re -f lavfi -i "testsrc=size=1280x720:rate=30" -t 60 -c:v libx264 -preset veryfast -pix_fmt yuv420p -f rtsp -rtsp_transport tcp rtsp://192.168.49.2:30554/stream'
```

Observed:
- `tcpdump -i ogstun2` on the UPF: 1152 packets in 20s, `10.47.0.2 > 192.168.49.2.30554`
- mediamtx: `[RTSP] [conn 10.47.0.2:52712] opened` — the UE's real, un-NAT'd
  address (gateway Service uses `externalTrafficPolicy: Local`)
- edge-ingest: `VLM caption: The frame shows a television test pattern with
  a rainbow of colors and a digital number "18" displayed in a black square.`
- `/status`: `{"last_caption": "...test pattern ... number \"33\"...", "connected": true}`
  (port-forward to a local port other than 8080 if something else holds it)

## What "end to end" means here

`scripts/stream-test-video.sh` already works standalone against the K3s
NodePort for Phase 5 testing (video in, no simulated radio path involved).
The *full* Phase 7 path additionally requires the video to genuinely transit
the simulated UE's tunnel:

```
ffmpeg (inside ueransim-ue) --(RTSP/TCP)--> uesimtun1 (edge DNN, Phase 3)
  --> gNB (simulated radio link) --> UPF's ogstun2 (edge DNN, un-NAT'd)
  --> host route (edge/setup-local-breakout-route.sh, Phase 3)
  --> K3s NodePort 30554 --> edge-gateway (mediamtx) --> edge-ingest (YOLO)
  --> vlm --> caption logged + exposed at edge-ingest's /status
```

The one subtlety that makes this different from just running
`stream-test-video.sh` from inside the container: the UE has **two** tunnel
interfaces (`uesimtun0` for `internet`, `uesimtun1` for `edge`), and by
default only one of them is the container's default route. If you don't
force the routing, ffmpeg's traffic silently takes the `internet` DNN path
instead — it would still probably reach the K3s NodePort (the UPF host can
route there regardless), but masqueraded through `ogstun`'s NAT rule, which
defeats the entire point of Phase 3 (proving the *edge* DNN's un-NAT'd path
carries real traffic to the K3s cluster with the UE's original source IP).
An earlier draft of this guide tried to force this with ffmpeg's
`-bind_address` flag; that's not reliable, because binding a socket to a
local address doesn't by itself change which interface the kernel's route
lookup picks for an off-subnet destination like the K3s node's LAN IP — you
can get `Cannot assign requested address` or, worse, have it silently
succeed via the wrong interface. Adding an explicit host route for the one
destination IP is deterministic and is what this guide uses instead.

## Step-by-step: stream a video through the UE and get a VLM caption back

Do this after Phases 1–6 are each individually verified (their own DoD
checklists) — Phase 7 only proves they compose, it can't fix a broken link
in any one of them. In particular, **Phase 3's local breakout must already
be verified** (`uesimtun1` up, `edge/setup-local-breakout-route.sh` run on
the host) before continuing here.

### 1. Confirm the edge tunnel is up

```bash
docker exec ueransim-ue ip -4 addr show uesimtun1
```

You should see an address in `10.47.0.0/16`. If the interface doesn't
exist at all, the subscriber's `edge` DNN session was never established —
most likely because the `edge` DNN session was only added to the
subscriber (via the WebUI, per `provision-subscriber.sh`'s final message)
*after* the UE container last started, so its one-time initial
registration never requested it successfully. Fix it either by restarting
the UE so it re-registers with both sessions from `ran/ue-config.yaml`:

```bash
docker compose -f ran/docker-compose.yml --env-file .env restart ue
```

or, without dropping the existing `internet` session, bring the `edge`
session up live:

```bash
docker exec ueransim-ue nr-cli imsi-${TEST_IMSI} --exec "ps-establish IPv4 --sst 1 --dnn edge"
```

Re-run the `ip addr show uesimtun1` check above until it shows an address.

### 2. Force this one destination through the edge tunnel

Inside the UE container, add a host route for the K3s node's IP via
`uesimtun1` specifically (leave everything else on the default route, so
the `internet` DNN session is untouched):

```bash
docker exec ueransim-ue ip route add ${EDGE_NODE_IP}/32 dev uesimtun1
```

(`EDGE_NODE_IP` is the same value you set in `.env` for Phase 3/5 — the
K3s node's LAN-reachable IP.)

### 3. Start a capture so you can see the traffic actually take this path

In a separate terminal, before streaming:

```bash
docker exec open5gs-upf tcpdump -i ogstun2 -n
```

This is the Phase 3 DoD check, reused here — you're watching the UPF's
`edge` DNN TUN device, which only carries traffic if the route from step 2
is actually in effect.

### 4. Stream a video from inside the UE container

```bash
docker exec -it ueransim-ue bash
apt-get update && apt-get install -y ffmpeg   # skip if already present in the image

ffmpeg -re -f lavfi -i "testsrc=size=1280x720:rate=30" -t 60 \
  -c:v libx264 -preset veryfast -f rtsp -rtsp_transport tcp \
  rtsp://${EDGE_NODE_IP}:30554/stream
```

(Pass a real video file instead of the `lavfi` test pattern the same way
`scripts/stream-test-video.sh` does, if you want the VLM to describe
something more interesting than a test card: `ffmpeg -re -stream_loop -1
-i /path/to/video.mp4 -t 60 -c:v libx264 -preset veryfast -f rtsp
-rtsp_transport tcp rtsp://${EDGE_NODE_IP}:30554/stream`.)

While this runs, the `tcpdump` from step 3 should show a steady stream of
TCP segments on `ogstun2` with a `10.47.x.x` source address — that's the
UE's real tunnel IP, proving the video is transiting the simulated 5G data
path, not just reaching the cluster from the Docker host directly.

### 5. Watch it get ingested and described

```bash
kubectl logs -l app=edge-ingest -f
```

Within a few seconds you should see `Connected to rtsp://edge-gateway:8554/stream`,
then periodic detection activity, then (after `VLM_SAMPLE_EVERY_N_FRAMES`
frames, ~5s of video by default) a line like `VLM caption: ...`. You can
also poll the ingest service's own status directly:

```bash
kubectl port-forward svc/edge-ingest 8080:8080 &
curl -s http://localhost:8080/status | python3 -m json.tool
```

`last_caption` holds the most recent VLM-generated description, and
`last_detection_count` the most recent YOLO detection count — both updating
live as the stream plays.

### 6. Clean up

```bash
docker exec ueransim-ue ip route del ${EDGE_NODE_IP}/32 dev uesimtun1
```

## DoD (copy real output here once run on the target host)

- [x] a single documented command sequence (steps 1–5 above) demonstrates
      video entering at the simulated UE and a VLM-generated caption
      coming out at the edge, with no manual intervention beyond starting it
- [x] `docker exec open5gs-upf tcpdump -i ogstun2` shows the stream's packets
      during the run (proving it actually used the local-breakout path, not
      a shortcut straight from the host)
- [x] `curl .../status` on `edge-ingest` shows a non-null `last_caption`

## Known risks to watch for on first real run

- This phase is the integration point for every risk flagged in
  phase-2/3/5/6's notes — if it fails, use those notes' individual DoD steps
  to isolate which link in the chain is broken before assuming the
  end-to-end wiring itself is wrong.
- Step 2's route is UE-container-local and does not survive a UE restart —
  re-add it (and re-check step 1) after any `docker compose restart ue`.
- If step 4's `ffmpeg` connects but the `tcpdump` in step 3 stays silent,
  the route from step 2 didn't take — double check `EDGE_NODE_IP` matches
  exactly (a trailing space or wrong interface name is the usual cause) and
  that `ip route show` inside the container lists it against `uesimtun1`.
