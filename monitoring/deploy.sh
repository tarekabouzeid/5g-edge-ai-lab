#!/usr/bin/env bash
# Phase 8: deploy Prometheus + Grafana onto the minikube edge cluster (run
# after ./lab.sh minikube up). The GPU panels are fed by
# scripts/host-gpu-exporter.py, which './lab.sh portal up' starts on the host.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi

echo "Deploying monitoring onto kubectl context: $(kubectl config current-context)"

kubectl apply -f monitoring/manifests/prometheus.yaml

kubectl create secret generic grafana-admin \
  --from-literal=password="${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap grafana-dashboard-gpu-pipeline \
  --from-file=monitoring/grafana-dashboards/gpu-and-pipeline.json \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f monitoring/manifests/grafana.yaml

echo
echo "Waiting for Grafana to become Ready..."
kubectl wait --for=condition=Available deployment/grafana --timeout=120s

echo
# minikube's NodePorts live on the node container's IP, which a Windows
# browser (WSL2) can't reach — forward to this host's localhost instead.
echo "Grafana: kubectl port-forward --address 0.0.0.0 svc/grafana 3000:3000"
echo "         then http://localhost:3000  (login: admin / \$GRAFANA_ADMIN_PASSWORD)"
echo "GPU panels are fed by the host GPU exporter that './lab.sh portal up' starts."
echo "Dashboard 'GPU & Pipeline' should already be provisioned under Dashboards."
