# Phase 7 — End-to-End Integration

## Status: Scaffolded, not yet run (see phase-0.md for why)

## What "end to end" means here

`scripts/stream-test-video.sh` already works standalone against the K3s
NodePort for Phase 5 testing. The *full* Phase 7 path additionally requires
the video to genuinely transit the simulated UE's tunnel:

```
ffmpeg --(RTSP)--> uesimtun1 (edge DNN, Phase 2/3) --> gNB --> UPF (edge DNN,
un-NAT'd) --> host route (Phase 3) --> K3s NodePort --> edge-gateway (mediamtx)
--> edge-ingest --> vlm --> caption logged
```

## How to run this for real (on the actual host, after Phases 1-6)

```bash
# From inside the UERANSIM UE container, so the traffic actually uses uesimtun1:
docker exec -it ueransim-ue bash
apt-get update && apt-get install -y ffmpeg   # if not already present in the image
ffmpeg -re -f lavfi -i "testsrc=size=1280x720:rate=30" -t 60 \
  -c:v libx264 -preset veryfast -f rtsp -rtsp_transport tcp \
  -bind_address <uesimtun1 IP> \
  rtsp://<EDGE_NODE_IP>:30554/stream
```

(`scripts/stream-test-video.sh` runs the equivalent command from the host
directly, which is sufficient for Phase 5's isolated DoD but does not
exercise the tunnel — use the command above, or extend the script with a
`--bind-address` flag reading the UE's tunnel IP, for the real Phase 7 DoD.)

## DoD (copy real output here once run on the target host)

- [ ] a single documented command demonstrates video entering at the
      simulated UE and a VLM-generated caption coming out at the edge, with
      no manual intervention beyond starting it
- [ ] `docker exec open5gs-upf tcpdump -i ogstun2` shows the stream's packets
      during the run (proving it actually used the local-breakout path, not
      a shortcut straight from the host)

## Known risks to watch for on first real run

- This phase is the integration point for every risk flagged in
  phase-2/3/5/6's notes — if it fails, use those notes' individual DoD steps
  to isolate which link in the chain is broken before assuming the
  end-to-end wiring itself is wrong.
