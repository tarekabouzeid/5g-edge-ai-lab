# Presenting the lab live

Three screens, left to right: the **demo page** (the story), **Grafana**
(the hardware), and a **terminal** (the proof).

## Bring-up (≈2 min, core + RAN already running)

```bash
minikube start --driver=docker --container-runtime=docker --gpus=nvidia.com
kubectl rollout status deploy/vlm deploy/edge-ingest deploy/edge-gateway
nohup ./scripts/host-gpu-exporter.py >/tmp/host-gpu-exporter.log 2>&1 &   # GPU panels in Grafana
./scripts/demo-stream-from-ue.sh            # loops demo-media/traffic.mp4 from inside the UE

kubectl port-forward --address 0.0.0.0 svc/edge-ingest 18080:8080 &
kubectl port-forward --address 0.0.0.0 svc/grafana 3000:3000 &
```

`demo-media/traffic.mp4` is git-ignored — fetch it once with
`curl -L -o demo-media/traffic.mp4 https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4`,
or pass any other file: `./scripts/demo-stream-from-ue.sh path/to/clip.mp4`.

| Screen | URL (works from the Windows browser too) | Login |
|---|---|---|
| Demo page | http://localhost:18080 | — |
| Grafana → Dashboards → "GPU & Pipeline" | http://localhost:3000 | `admin` / `GRAFANA_ADMIN_PASSWORD` from `.env` |
| Open5GS WebUI (subscriber provisioning) | http://localhost:9999 | `admin` / `1423` |

Proof terminal — packets scrolling with the UE's own IP:

```bash
docker exec open5gs-upf tcpdump -i ogstun2 -n
```

## Suggested flow

1. **Open5GS WebUI** — "this is a real 5G core; here is the subscriber (IMSI) our simulated phone uses."
2. **Demo page, pipeline strip** — every hop lights up green. The UE card and
   the video badge show `10.47.0.2`: the address the core assigned on the
   `edge` DNN. The RTSP gateway in Kubernetes sees that same address — no NAT,
   traffic broke out locally at the edge instead of travelling to a central core.
3. **tcpdump terminal** — the same packets, captured on the UPF's edge tunnel.
4. **Demo page, video + captions** — YOLO boxes on CPU, a GPU VLM describing the scene every ~3s in well under a second.
5. **Grafana** — GPU memory held by the model, power spikes per caption, tokens/s, ingest fps.
6. Optional contrast: stream from the host instead
   (`./scripts/stream-test-video.sh` with `EDGE_NODE_IP=$(minikube ip)`) — the
   page turns amber and marks the radio/core hops "bypassed".

## Stop / reset

```bash
./scripts/demo-stream-from-ue.sh stop
pkill -f "[h]ost-gpu-exporter.py"
```

Known gaps: the Open5GS targets in Prometheus show "down" on minikube (Docker
blocks cross-bridge traffic to the core network without host firewall
changes); the routing from `edge/setup-minikube-breakout.sh` and ffmpeg inside
the UE don't survive restarts — `demo-stream-from-ue.sh` redoes both.
