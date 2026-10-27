#!/usr/bin/env bash
# Single entrypoint for controlling every layer of this lab. Wraps the
# per-phase scripts in core/, ran/, edge/, monitoring/, portal/ — this file
# adds no logic of its own beyond sequencing and teardown.
#
# Usage: ./lab.sh <target> <action>
#
#   ./lab.sh all up|down                      Whole lab from scratch
#   ./lab.sh core up|down|status|logs         Open5GS 5G core (Phase 1)
#   ./lab.sh ran up|down|status|logs          UERANSIM gNB + two UEs (Phase 2)
#   ./lab.sh minikube up|down|status          Edge cluster: minikube + GPU, ingest image (Phase 4)
#   ./lab.sh edge-apps up|down                Envoy front door + authz + RTSP gateway + ingest + VLM (Phases 5/6/9)
#   ./lab.sh breakout up                      Local-breakout routing UE -> UPF -> minikube, phone credentials (Phase 3/7/9)
#   ./lab.sh monitoring up|down               Prometheus + Grafana (Phase 8)
#   ./lab.sh portal up|down|logs              Lab portal at http://localhost:8090 (+ GPU exporter)
#   ./lab.sh status                           Summary across every layer
#
# 'down' is always non-destructive (stops what 'up' started, keeps data —
# MongoDB's volume, the minikube cluster, the model cache).
# Use 'minikube delete' to actually remove the cluster.
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 1; }

# Both phones' subscriptions (UE 2's IMSI is TEST_IMSI_2).
core_up()   { (cd core && docker compose --env-file ../.env up -d) && ./scripts/provision-subscriber.sh \
                && ./scripts/provision-subscriber.sh "$(grep -m1 -oP '^TEST_IMSI_2=\K.*' .env || echo 999700000000002)"; }
core_down() { (cd core && docker compose --env-file ../.env down); }
core_status() { (cd core && docker compose ps); }
core_logs() { (cd core && docker compose logs -f "$@"); }

ran_up()   { (cd ran && docker compose --env-file ../.env up -d) && ./scripts/verify-pdu-session.sh ueransim-ue \
                && ./scripts/verify-pdu-session.sh ueransim-ue2; }
ran_down() { (cd ran && docker compose --env-file ../.env down); }
ran_status() { (cd ran && docker compose ps); }
ran_logs() { (cd ran && docker compose logs -f "$@"); }

minikube_up()     { ./edge/minikube-up.sh; }
minikube_down()   { echo "Stopping minikube (non-destructive — 'minikube delete' removes it)."; minikube stop; }
minikube_status() { minikube status || true; kubectl get node -o wide 2>/dev/null || true; }

edge_apps_up() {
  # The VLM's hostPath model cache lives on the node, i.e. inside the
  # minikube container, not on this host.
  minikube ssh -- sudo mkdir -p /opt/edge-lab/hf-cache
  # Edge security (docs/security.md): Envoy Gateway as the front door; the
  # operator PKI, token-signing key and service secrets (generated on first
  # run, git-ignored) loaded into Secrets/ConfigMaps the manifests reference.
  ./edge/envoy-gateway-up.sh
  ./scripts/edge-keys.sh apply
  ./scripts/edge-pki.sh apply
  kubectl apply -f edge/manifests/authz.yaml -f edge/manifests/gateway.yaml \
    -f edge/manifests/ingest-deployment.yaml -f edge/manifests/vlm-deployment.yaml -f edge/manifests/edge-envoy.yaml
  kubectl wait --for=condition=Available deployment/edge-authz deployment/edge-gateway deployment/edge-ingest --timeout=180s
  kubectl wait --for=condition=Programmed gateway/edge --timeout=180s
  # The first start downloads ~9 GB (model + vision projector) into the
  # hostPath cache — ~30 min on the verified host; later starts take seconds.
  echo "Waiting for the VLM (first start downloads ~9 GB and can take 30+ min;"
  echo "follow it with: kubectl logs -f deploy/vlm)..."
  kubectl wait --for=condition=Available deployment/vlm --timeout=3600s || {
    echo "VLM still not ready after 60 min — check 'kubectl logs deploy/vlm --tail=40'." >&2
    echo "If it's still downloading, wait and re-run './lab.sh all up' (finished steps are skipped quickly)." >&2
    exit 1; }
}
edge_apps_down() { kubectl delete -f edge/manifests/edge-envoy.yaml -f edge/manifests/vlm-deployment.yaml \
                     -f edge/manifests/ingest-deployment.yaml -f edge/manifests/gateway.yaml \
                     -f edge/manifests/authz.yaml --ignore-not-found; }

# Routing for both phones, then their edge credentials + EEC (the operator's
# out-of-band provisioning, docs/security.md).
breakout_up() { ./edge/setup-minikube-breakout.sh && ./scripts/edge-pki.sh provision-ues; }

# The GPU panels are fed by the host GPU exporter that 'portal up' starts.
monitoring_up() { ./monitoring/deploy.sh; }
monitoring_down() { kubectl delete -f monitoring/manifests/grafana.yaml -f monitoring/manifests/prometheus.yaml --ignore-not-found
                     kubectl delete configmap grafana-dashboard-gpu-pipeline --ignore-not-found
                     kubectl delete secret grafana-admin --ignore-not-found; }

portal_compose() {
  local profile=()
  docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia && profile=(--profile gpu)
  PORTAL_EDGE_NODE_IP="$(minikube ip 2>/dev/null || echo 192.168.49.2)" \
    docker compose -f portal/docker-compose.yml --env-file .env "${profile[@]}" "$@"
}
portal_up()   { ./scripts/fetch-demo-media.sh
                ./scripts/edge-pki.sh init      # the portal's client certificate
                portal_compose up -d --build
                echo "Lab portal: http://localhost:8090"; }
portal_down() { portal_compose down; }
portal_logs() { portal_compose logs -f; }

status() {
  echo "=== core (Open5GS) ==="; (cd core && docker compose ps 2>/dev/null) || echo "not running"
  echo; echo "=== ran (UERANSIM) ==="; (cd ran && docker compose ps 2>/dev/null) || echo "not running"
  echo; echo "=== portal ==="; docker ps --filter name=edge-lab- --format '{{.Names}}\t{{.Status}}' || true
  echo; echo "=== kubectl context: $(kubectl config current-context 2>/dev/null || echo none) ==="
  kubectl get pods -A 2>/dev/null || echo "no cluster reachable"
}

# Order matters: the core must exist before the RAN attaches, the cluster
# before the apps, and the breakout needs both the UPF and the cluster.
all_up() {
  core_up; ran_up; minikube_up; edge_apps_up; breakout_up; monitoring_up; portal_up
  echo
  echo "Lab is up. Open http://localhost:8090 — see docs/demo.md for the presenter flow."
}
all_down() {
  portal_down; monitoring_down; edge_apps_down; minikube_down; ran_down; core_down
}

[ -f .env ] || { echo "No .env found — copy .env.example to .env first."; exit 1; }

target="${1:-}"; action="${2:-}"
if [ "$#" -ge 2 ]; then shift 2; elif [ "$#" -ge 1 ]; then shift 1; fi

case "${target}:${action}" in
  all:up) all_up ;;           all:down) all_down ;;
  core:up) core_up ;;         core:down) core_down ;;
  core:status) core_status ;; core:logs) core_logs "$@" ;;
  ran:up) ran_up ;;           ran:down) ran_down ;;
  ran:status) ran_status ;;   ran:logs) ran_logs "$@" ;;
  minikube:up) minikube_up ;; minikube:down) minikube_down ;; minikube:status) minikube_status ;;
  edge-apps:up) edge_apps_up ;; edge-apps:down) edge_apps_down ;;
  breakout:up) breakout_up ;;
  monitoring:up) monitoring_up ;; monitoring:down) monitoring_down ;;
  portal:up) portal_up ;;     portal:down) portal_down ;;  portal:logs) portal_logs ;;
  status:) status ;;
  *) usage ;;
esac
