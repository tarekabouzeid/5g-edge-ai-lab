#!/usr/bin/env bash
# Phase 8: deploy Prometheus + Grafana (+ DCGM exporter, unless --no-gpu) onto
# whichever cluster is kubectl's current context. Run after the edge cluster
# (either edge/k3s-install.sh + install-gpu-operator.sh, or edge/kind/kind-up.sh)
# is up.
#
# --no-gpu: skip DCGM exporter entirely (used by edge/kind/kind-up.sh, since
# a plain KIND cluster has no GPU and no gpu-operator namespace for it to
# join) — Grafana's GPU panels will simply stay empty in that mode.
set -euo pipefail

NO_GPU=false
if [ "${1:-}" = "--no-gpu" ]; then
  NO_GPU=true
fi

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi

echo "Deploying monitoring onto kubectl context: $(kubectl config current-context)"

if [ "${NO_GPU}" = true ]; then
  echo "--no-gpu: skipping DCGM exporter"
elif kubectl get pods -n gpu-operator -l app=nvidia-dcgm-exporter --no-headers 2>/dev/null | grep -q .; then
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
if [ "$(kubectl config current-context)" = "minikube" ]; then
  # minikube's NodePorts live on the node container's IP, which a Windows
  # browser (WSL2) can't reach — forward to this host's localhost instead.
  echo "Grafana: kubectl port-forward --address 0.0.0.0 svc/grafana 3000:3000"
  echo "         then http://localhost:3000  (login: admin / \$GRAFANA_ADMIN_PASSWORD)"
  echo "GPU panels are fed by the host GPU exporter that './lab.sh portal up' starts."
else
  echo "Grafana: http://${EDGE_NODE_IP:-localhost}:30300  (login: admin / \$GRAFANA_ADMIN_PASSWORD)"
  if [ "${NO_GPU}" = true ]; then
    echo "(GPU panels will be empty in --no-gpu/KIND mode — that's expected.)"
  fi
fi
echo "Dashboard 'GPU & Pipeline' should already be provisioned under Dashboards."
