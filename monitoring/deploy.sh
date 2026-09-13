#!/usr/bin/env bash
# Phase 8: deploy Prometheus + DCGM exporter + Grafana onto the K3s cluster.
# Run after Phase 4 (K3s + GPU Operator) is up.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "Checking for an existing dcgm-exporter from the GPU Operator..."
if kubectl get pods -n gpu-operator -l app=nvidia-dcgm-exporter --no-headers 2>/dev/null | grep -q .; then
  echo "GPU Operator already runs dcgm-exporter — skipping monitoring/manifests/dcgm-exporter.yaml"
else
  kubectl apply -f monitoring/manifests/dcgm-exporter.yaml
fi

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
echo "Grafana: http://${EDGE_NODE_IP:-<node-ip>}:30300  (login: admin / \$GRAFANA_ADMIN_PASSWORD)"
echo "Dashboard 'GPU & Pipeline' should already be provisioned under Dashboards."
echo
echo "Phase 8 DoD: run scripts/stream-test-video.sh and confirm the GPU"
echo "utilization / frames-per-second panels move while it runs."
