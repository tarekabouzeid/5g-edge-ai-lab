# Phase 8 — Observability

## Status: Run on the WSL2 host (minikube), 2026-09-24 — DoD met

NVIDIA's DCGM doesn't run under WSL2, so the GPU panels are fed by `scripts/host-gpu-exporter.py` (nvidia-smi → the same
`DCGM_FI_DEV_*` metric names), run as the `gpu-exporter` service in
`portal/docker-compose.yml` and scraped at `192.168.49.1:9400`. Prometheus
also scrapes the VLM (llama.cpp `--metrics`: tokens/s, shown in a dashboard
panel) and edge-ingest. Verified: every dashboard query returns data (GPU
util/memory/temp/power, ingest fps, detections/s, VLM p50 latency, ~230
tokens/s). Grafana on minikube: `kubectl port-forward --address 0.0.0.0
svc/grafana 3000:3000` → http://localhost:3000.

## What was built

- `monitoring/manifests/prometheus.yaml`: a minimal, Helm/Operator-free
  Prometheus Deployment with static scrape targets (edge-ingest, the VLM,
  the host GPU exporter).
- `monitoring/manifests/grafana.yaml` + `monitoring/grafana-dashboards/
  gpu-and-pipeline.json`: Grafana with the Prometheus datasource and one
  dashboard auto-provisioned (GPU utilization/memory/temperature, ingest
  frames/sec, VLM latency percentiles, detections/sec, VLM tokens/s, GPU
  power).
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

## Known risks

- **Open5GS NF metrics aren't scraped from the cluster.** Docker drops
  traffic to a container IP arriving from a different bridge, so a pod on
  minikube can't reach the NFs' `10.10.0.x:9090` endpoints without host
  firewall changes (sudo). The lab portal reads the same Open5GS metrics
  from the host instead and shows the core counters live. (A scrape job for
  them existed but was always DOWN on minikube; removed 2026-09-25.)
- Existing clusters deployed before 2026-09-25 still have the old
  Prometheus RBAC objects (`prometheus` ServiceAccount/ClusterRole/Binding)
  from when it discovered DCGM pods; they're unused and harmless
  (`kubectl delete clusterrolebinding,clusterrole prometheus; kubectl delete sa prometheus`
  removes them).
