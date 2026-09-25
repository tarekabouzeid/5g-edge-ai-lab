# Phase 7 — End-to-End Integration

## Status: DoD verified on the WSL2 host (minikube, RTX 5070 Ti), 2026-09-24

The whole thing is one command — `./lab.sh all up`, then the lab portal
(http://localhost:8090, `docs/demo.md`) drives the phone's camera, routing
and path selection itself. The manual steps below explain what happens
underneath.

Single-GPU layout: only `vlm` (llama.cpp + Gemma 4 E4B GGUF) requests
`nvidia.com/gpu`; `edge-ingest` runs YOLOv8n on CPU, so both run together
on one GPU without time-slicing.

## What "end to end" means here

`scripts/stream-test-video.sh` streams from the host straight to the
gateway NodePort — that only exercises Phase 5. The *full* path has the
video genuinely transit the simulated UE's edge tunnel:

```
ffmpeg (inside ueransim-ue) --(RTSP/TCP)--> uesimtunN (edge DNN, 10.47.x.x)
  --> gNB (simulated radio link) --> UPF's ogstun2 (edge DNN, un-NAT'd)
  --> UPF's leg on the minikube network (edge/setup-minikube-breakout.sh)
  --> NodePort 30554 on the minikube node --> edge-gateway (mediamtx)
  --> edge-ingest (YOLO) --> vlm --> caption at edge-ingest's /status
```

The subtlety: the UE has **two** tunnel interfaces (one per DNN), and only
one is the container's default route. Unforced, ffmpeg's traffic silently
takes the `internet` DNN and still reaches the node — but masqueraded
through `ogstun`'s NAT, which defeats the point of Phase 3. ffmpeg's
`-bind_address` doesn't reliably fix this (binding a local address doesn't
change the kernel's route lookup); an explicit host route for the node IP
via the edge tunnel does. `setup-minikube-breakout.sh` (and the portal)
add that route, picking the tunnel by its `10.47.x.x` address because the
uesimtunN ↔ DNN mapping changes between attaches.

## Step-by-step: stream through the UE and get a VLM caption back

Do this after Phases 1–6 are each verified — Phase 7 only proves they
compose.

```bash
# 1. Edge tunnel up? Look for the interface holding a 10.47.x.x address.
docker exec ueransim-ue ip -4 -o addr
#    None? The edge session wasn't established — bring it up live:
#    docker exec ueransim-ue nr-cli imsi-${TEST_IMSI} --exec "ps-establish IPv4 --sst 1 --dnn edge"

# 2. Breakout routing (UPF <-> minikube, and the UE's route to the node IP)
./lab.sh breakout up

# 3. Watch the UPF's edge-DNN TUN device (separate terminal)
docker exec open5gs-upf tcpdump -i ogstun2 -n

# 4. Stream from inside the UE (ffmpeg install is once per UE container)
docker exec ueransim-ue sh -c 'apt-get update -qq && apt-get install -y -qq ffmpeg'
docker exec -d ueransim-ue sh -c "ffmpeg -nostdin -re -f lavfi -i testsrc=size=1280x720:rate=30 -t 60 \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -f rtsp -rtsp_transport tcp rtsp://$(minikube ip):30554/stream"

# 5. Watch it get ingested and described
kubectl logs -l app=edge-ingest -f          # "VLM caption: ..." every VLM_INTERVAL_SECONDS (4 s)
kubectl port-forward svc/edge-ingest 18080:8080 &
curl -s http://localhost:18080/status | python3 -m json.tool
```

`scripts/demo-stream-from-ue.sh` wraps steps 2–4 with a real video file.

## DoD (real output, WSL2 host, 2026-09-24)

- [x] one documented command sequence (above) takes video in at the
      simulated UE and gets a VLM caption out at the edge
- [x] `tcpdump -i ogstun2` on the UPF shows the stream during the run:
      1152 packets in 20 s, `10.47.0.2 > 192.168.49.2.30554`
- [x] mediamtx logs `[RTSP] [conn 10.47.0.2:52712] opened` — the UE's real,
      un-NAT'd address (the gateway Service uses
      `externalTrafficPolicy: Local`)
- [x] `/status` on `edge-ingest` shows a non-null `last_caption`, e.g.
      `The frame shows a television test pattern with a rainbow of colors
      and a digital number "18" displayed in a black square.`

## Known risks

- This phase is the integration point for every risk in phase-2/3/5/6's
  notes — if it fails, use those notes' own DoD steps to isolate the broken
  link first.
- The UE-side route is container-local runtime state: re-run
  `./lab.sh breakout up` after any minikube/UPF/UE restart (the portal
  re-applies the UE-side route by itself).
- If ffmpeg connects but `tcpdump` on `ogstun2` stays silent, the traffic
  took the internet DNN — check `docker exec ueransim-ue ip route` lists the
  node IP against the `10.47.x.x` tunnel.
- If local port 8080 is taken, port-forward to another local port (as
  above).
