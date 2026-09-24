# Presenting the lab live

The **lab portal** (`portal/`, http://localhost:8090) is the presentation
surface: one screen with no scrolling (checked from 1366×700 up to 1920×1080),
left to right — the phone, the 5G core, the edge AI — with the operator
controls on it. Everything it shows is read from the live
system (nr-cli, the network functions' own logs, Open5GS metrics, the UPF's
interfaces, round trips measured from inside the phone). The one emulated
piece is the central cloud's WAN distance, and the page says so.

## Bring-up

```bash
./lab.sh all up          # whole lab from scratch; ~2 min when images/model are cached
```

That runs core → RAN → minikube + GPU → edge apps → local-breakout routing →
monitoring → portal (which also downloads the sample clips into
`demo-media/`, git-ignored, and starts the GPU exporter for Grafana). If
parts are already up, the individual targets are `./lab.sh <target> up`
(see `./lab.sh`). Grafana is optional:
`kubectl port-forward --address 0.0.0.0 svc/grafana 3000:3000 &`.

Open http://localhost:8090 (works from the Windows browser on WSL2). The
portal binds to 127.0.0.1 only — it holds the Docker socket. Other clips:
drop them into `demo-media/` or onto the portal's upload box (drone /
search-and-rescue footage: MOBDrone, Okutama-Action, SeaDronesSee, VisDrone).

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
7. **Ask the camera** (tab under the video, or press `/`): type a question —
   "Is anyone not wearing a hard hat?" — and the vision-language model answers
   from the live frame on the edge GPU, typically in 0.2–1.5 s.
8. **Alert rules** (*Alerts* tab): *+ Zone* lets you drag a rectangle on the
   video — the zone turns red and an alert with a snapshot is logged the moment
   a person's feet enter it (great with *Worker zone detection*). *+ Count*
   alerts on N+ objects; *+ Ask the AI* puts a yes/no question to the VLM every
   few seconds (a disabled "Missing hard hat" example is pre-loaded). Rules
   persist in `demo-media/.portal-rules.json`.

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
| Edge-only page (in-cluster, no controls) | `kubectl port-forward svc/edge-ingest 18080:8080` → http://localhost:18080 (or http://$(minikube ip):30080 from WSL) | — |

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
