# Presenting the lab live

The **lab portal** (`portal/`, http://localhost:8090) is the presentation
surface: one screen, left to right — the phone, the 5G core, the edge AI —
with the operator controls on it. Everything it shows is read from the live
system (nr-cli, the network functions' own logs, Open5GS metrics, the UPF's
interfaces, round trips measured from inside the phone). The one emulated
piece is the central cloud's WAN distance, and the page says so.

## Bring-up (core + RAN + minikube edge already running)

```bash
./edge/setup-minikube-breakout.sh          # local breakout routing (re-run after minikube/UPF restarts)
./lab.sh portal up                         # builds + starts the portal
nohup ./scripts/host-gpu-exporter.py >/tmp/host-gpu-exporter.log 2>&1 &   # optional: GPU panels in Grafana
kubectl port-forward --address 0.0.0.0 svc/grafana 3000:3000 &           # optional: Grafana
```

Open http://localhost:8090 (works from the Windows browser on WSL2). The
portal binds to 127.0.0.1 only — it holds the Docker socket.

Sample clips live in `demo-media/` (git-ignored). Fetch them once:

```bash
mkdir -p demo-media && for v in person-bicycle-car-detection worker-zone-detection people-detection car-detection; do
  curl -sSfL -o demo-media/$v.mp4 https://github.com/intel-iot-devkit/sample-videos/raw/master/$v.mp4; done
```

…or drag any video onto the portal's upload box.

## Suggested flow (≈5 minutes)

1. **Phone off.** Press *Power off* first so the audience sees the network
   release it: deregistration at the AMF, sessions released at the SMF, radio
   released at the gNB.
2. **"Watch the phone come online."** Press *Power on*. The signalling timeline
   replays the real attach, event by event with real timestamps: cell found →
   RRC → registration (SUCI) → AUSF 5G-AKA → UDM → PCF → registration complete
   → SMF assigns IPs → UPF installs the user plane → tunnels up. The matching
   network functions light up in the diagram. The whole attach takes well under
   a second — the replay slows it down so people can follow.
3. **Start the camera** (pick *Worker zone detection* for an industrial-safety
   angle). The path lights up UE → gNB → UPF → edge site; the video badge shows
   the phone's own 10.47.x.x address arriving at the edge — no NAT, local breakout.
4. **Talk through the AI:** object detection per frame, and a GPU vision-language
   model describing the scene every ~3 s in ~0.2 s.
5. **Flip to *Central cloud*.** The video now leaves through the internet DNN,
   NAT'd at the UPF (the badge shows the phone hidden behind 10.10.0.7), across
   the emulated WAN. Point at the round-trip bars (≈1 ms vs ≈50 ms) and the
   time-to-insight breakdown. Drag the WAN slider to 100 ms for effect.
6. **Flip back to *Edge breakout*** — that's the case for edge compute.

Optional proof terminal: `docker exec open5gs-upf tcpdump -i ogstun2 -n` shows
the video packets on the UPF's edge interface with the phone's IP.

## If something goes wrong mid-demo

- **Radio stall** (a known UERANSIM bug where the simulated data path freezes):
  the portal detects it with a ping over the edge tunnel and re-attaches the
  phone by itself — it shows up in the timeline as "Radio link stalled —
  re-attaching". Takes ~6 s, the camera resumes on its own.
- **Edge AI pod restarted**: the video panel reconnects on its own.
- **Portal restarted**: it restores camera/video/path/WAN settings from
  `demo-media/.portal-state.json`.
- Portal logs: `./lab.sh portal logs`.

## Other screens

| Screen | URL | Login |
|---|---|---|
| Lab portal | http://localhost:8090 | — |
| Grafana → "GPU & Pipeline" | http://localhost:3000 | `admin` / `GRAFANA_ADMIN_PASSWORD` from `.env` |
| Open5GS WebUI (subscribers) | http://localhost:9999 | `admin` / `1423` |
| Edge-only page (in-cluster, no controls) | `kubectl port-forward svc/edge-ingest 18080:8080` → http://localhost:18080 | — |

`scripts/demo-stream-from-ue.sh` still works without the portal; with the
portal running it just asks the portal to start/stop the phone's camera.

## How it works (for questions from the audience)

- **Phone controls** are real UE operations: *Power off* is a switch-off
  deregistration (`nr-cli deregister switch-off`), *Power on* boots the UE,
  which does a full initial registration.
- **Edge vs central** switches which PDU session carries the video: the
  `edge` DNN (un-NAT'd, straight to the edge node) or the `internet` DNN
  (NAT'd at the UPF) to a relay in the portal that adds the WAN delay and
  forwards to the same AI. The WSL2 kernel has no `netem`, hence the relay.
- **Round trips** are HTTP requests made from inside the UE over each PDU
  session (request→first byte), every 3 s.
- **Time to insight** = one-way network (half the measured RTT) + detection
  time + VLM time, all live numbers.
