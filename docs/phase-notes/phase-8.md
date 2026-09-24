# Phase 8 — Observability

## Status: Run on the WSL2 host (minikube), 2026-09-24 — DoD met

On minikube there is no GPU Operator and NVIDIA's DCGM doesn't run under
WSL2, so `./lab.sh monitoring up` deploys with `--no-gpu` and the GPU panels
are fed by `scripts/host-gpu-exporter.py` (nvidia-smi → the same
`DCGM_FI_DEV_*` metric names), run as the `gpu-exporter` service in
`portal/docker-compose.yml` and scraped at `192.168.49.1:9400`. Prometheus
also scrapes the VLM (llama.cpp `--metrics`: tokens/s, shown in a dashboard
panel) and edge-ingest. Verified: every dashboard query returns data (GPU
util/memory/temp/power, ingest fps, detections/s, VLM p50 latency, ~230
tokens/s). Grafana on minikube: `kubectl port-forward --address 0.0.0.0
svc/grafana 3000:3000` → http://localhost:3000.

## What was built

- `monitoring/manifests/dcgm-exporter.yaml`: standalone DCGM exporter
  DaemonSet (only needed if the GPU Operator's own bundled dcgm-exporter
  sub-chart was disabled — `monitoring/deploy.sh` checks for that first).
- `monitoring/manifests/prometheus.yaml`: a minimal, Helm/Operator-free
  Prometheus Deployment with RBAC for pod discovery, config mirrored from
  `monitoring/prometheus/prometheus.yml`.
- `monitoring/manifests/grafana.yaml` + `monitoring/grafana-dashboards/
  gpu-and-pipeline.json`: Grafana with the Prometheus datasource and one
  dashboard auto-provisioned (GPU utilization/memory/temperature, ingest
  frames/sec, VLM latency percentiles, detections/sec).
- `monitoring/deploy.sh`: applies all of the above in the right order,
  including creating the admin-password Secret and dashboard ConfigMap via
  `kubectl create ... --dry-run=client -o yaml | kubectl apply -f -` so
  neither needs hand-escaping into raw YAML.

## How to run this for real (on the actual host, after Phase 4)

```bash
./monitoring/deploy.sh
# then in another terminal, generate load:
./scripts/stream-test-video.sh
```

## DoD (copy real output here once run on the target host)

- [x] Grafana dashboard's GPU utilization/memory panels visibly move when
      video streams, and settle back down when it stops

## Known risks to watch for on first real run

- Prometheus's `open5gs-core` scrape job targets the Open5GS NFs' docker
  bridge IPs (`10.10.0.x:9090`) directly from inside a K3s pod — this
  depends on the K3s node's routing table already having a route to that
  bridge subnet (Docker sets this up automatically when the network is
  created) and no firewall blocking pod-to-host-bridge traffic. If those
  targets show as `DOWN` in Prometheus's `/targets` page, check
  `ip route show 10.10.0.0/24` on the host first. **On minikube they are
  always DOWN**: Docker drops traffic to a container IP arriving from a
  different bridge, and fixing that needs host firewall changes (sudo). The
  lab portal reads the same Open5GS metrics from the host instead and shows
  the core counters live.
- If the GPU Operator's own dcgm-exporter is already running (the common
  case — it's enabled by default in the chart), applying
  `dcgm-exporter.yaml` on top of it would double-count / contend for the
  GPU; `monitoring/deploy.sh` checks for this, but verify manually with
  `kubectl get pods -n gpu-operator` if metrics look doubled.
