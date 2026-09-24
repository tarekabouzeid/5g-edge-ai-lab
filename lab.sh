#!/usr/bin/env bash
# Single entrypoint for controlling every layer of this lab. Wraps the
# per-phase scripts in core/, ran/, edge/, monitoring/, portal/ — this file
# adds no logic of its own beyond sequencing and teardown.
#
# Usage: ./lab.sh <target> <action> [flags]
#
#   ./lab.sh all up|down [--k3s]              Whole lab from scratch (default: minikube path, see below)
#   ./lab.sh core up|down|status|logs         Open5GS 5G core (Phase 1)
#   ./lab.sh ran up|down|status|logs          UERANSIM gNB+UE (Phase 2)
#   ./lab.sh minikube up|down|status          Edge cluster: minikube + GPU, ingest image (Phase 4, verified path)
#   ./lab.sh k3s up|down|uninstall            Edge cluster alternative: K3s + GPU Operator (Phase 4, bare-metal Linux)
#   ./lab.sh kind up|down                     Local dev/test: KIND, no GPU (see edge/kind/README.md)
#   ./lab.sh edge-apps up|down                RTSP gateway + ingest + VLM (Phases 5/6)
#   ./lab.sh breakout up                      Local-breakout routing UE -> UPF -> minikube (Phase 3/7)
#   ./lab.sh monitoring up|down [--no-gpu]    Prometheus + Grafana (+ DCGM on K3s) (Phase 8)
#   ./lab.sh portal up|down|logs              Lab portal at http://localhost:8090 (+ GPU exporter)
#   ./lab.sh status                           Summary across every layer
#
# 'down' is always non-destructive (stops what 'up' started, keeps data —
# MongoDB's volume, the minikube cluster, K3s itself, the model cache).
# Use 'k3s uninstall' / 'minikube delete' to actually remove a cluster.
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 1; }
on_minikube() { [ "$(kubectl config current-context 2>/dev/null)" = "minikube" ]; }

core_up()   { (cd core && docker compose --env-file ../.env up -d) && ./scripts/provision-subscriber.sh; }
core_down() { (cd core && docker compose --env-file ../.env down); }
core_status() { (cd core && docker compose ps); }
core_logs() { (cd core && docker compose logs -f "$@"); }

ran_up()   { (cd ran && docker compose --env-file ../.env up -d) && ./scripts/verify-pdu-session.sh; }
ran_down() { (cd ran && docker compose --env-file ../.env down); }
ran_status() { (cd ran && docker compose ps); }
ran_logs() { (cd ran && docker compose logs -f "$@"); }

minikube_up()     { ./edge/minikube-up.sh; }
minikube_down()   { echo "Stopping minikube (non-destructive — 'minikube delete' removes it)."; minikube stop; }
minikube_status() { minikube status || true; kubectl get node -o wide 2>/dev/null || true; }

k3s_up()        { ./edge/k3s-install.sh && ./edge/install-gpu-operator.sh; }
k3s_down()      { echo "Stopping the k3s service (non-destructive — cluster state is kept; 'sudo systemctl start k3s' resumes it)."
                   sudo systemctl stop k3s; }
k3s_uninstall() { echo "This removes K3s entirely from this host (destructive)."; read -rp "Type 'yes' to continue: " c
                   [ "$c" = "yes" ] || { echo "Aborted."; exit 1; }
                   sudo /usr/local/bin/k3s-uninstall.sh; }

kind_up()   { ./edge/kind/kind-up.sh; }
kind_down() { ./edge/kind/kind-down.sh; }

edge_apps_up() {
  # The VLM's hostPath model cache lives on the node: inside the minikube
  # container on the minikube path, on this host for K3s.
  if on_minikube; then minikube ssh -- sudo mkdir -p /opt/edge-lab/hf-cache
  else mkdir -p /opt/edge-lab/hf-cache 2>/dev/null || sudo mkdir -p /opt/edge-lab/hf-cache; fi
  kubectl apply -f edge/manifests/gateway.yaml -f edge/manifests/ingest-deployment.yaml -f edge/manifests/vlm-deployment.yaml
  kubectl wait --for=condition=Available deployment/edge-gateway deployment/edge-ingest --timeout=180s
  echo "Waiting for the VLM (the first start downloads the model, ~2 GB)..."
  kubectl wait --for=condition=Available deployment/vlm --timeout=900s
}
edge_apps_down() { kubectl delete -f edge/manifests/vlm-deployment.yaml -f edge/manifests/ingest-deployment.yaml \
                     -f edge/manifests/gateway.yaml --ignore-not-found; }

breakout_up() {
  if on_minikube; then ./edge/setup-minikube-breakout.sh
  else echo "K3s path: run ./edge/setup-local-breakout-route.sh (needs sudo)."; fi
}

monitoring_up() {
  # No GPU Operator on minikube, so no DCGM: the GPU panels are fed by the
  # host GPU exporter that './lab.sh portal up' starts instead.
  if on_minikube; then ./monitoring/deploy.sh --no-gpu; else ./monitoring/deploy.sh "$@"; fi
}
monitoring_down() { kubectl delete -f monitoring/manifests/grafana.yaml -f monitoring/manifests/prometheus.yaml \
                       -f monitoring/manifests/dcgm-exporter.yaml --ignore-not-found
                     kubectl delete configmap grafana-dashboard-gpu-pipeline --ignore-not-found
                     kubectl delete secret grafana-admin --ignore-not-found; }

portal_compose() {
  local profile=()
  docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia && profile=(--profile gpu)
  PORTAL_EDGE_NODE_IP="$(minikube ip 2>/dev/null || echo 192.168.49.2)" \
    docker compose -f portal/docker-compose.yml --env-file .env "${profile[@]}" "$@"
}
portal_up()   { ./scripts/fetch-demo-media.sh
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
  if [ "${1:-}" = "--k3s" ]; then
    core_up; ran_up; k3s_up; edge_apps_up; monitoring_up; portal_up
    echo "K3s path: now run ./edge/setup-local-breakout-route.sh (needs sudo)."
  else
    core_up; ran_up; minikube_up; edge_apps_up; breakout_up; monitoring_up; portal_up
  fi
  echo
  echo "Lab is up. Open http://localhost:8090 — see docs/demo.md for the presenter flow."
}
all_down() {
  portal_down; monitoring_down; edge_apps_down
  if [ "${1:-}" = "--k3s" ]; then k3s_down; else minikube_down; fi
  ran_down; core_down
}

[ -f .env ] || { echo "No .env found — copy .env.example to .env first."; exit 1; }

target="${1:-}"; action="${2:-}"
if [ "$#" -ge 2 ]; then shift 2; elif [ "$#" -ge 1 ]; then shift 1; fi

case "${target}:${action}" in
  all:up) all_up "$@" ;;      all:down) all_down "$@" ;;
  core:up) core_up ;;         core:down) core_down ;;
  core:status) core_status ;; core:logs) core_logs "$@" ;;
  ran:up) ran_up ;;           ran:down) ran_down ;;
  ran:status) ran_status ;;   ran:logs) ran_logs "$@" ;;
  minikube:up) minikube_up ;; minikube:down) minikube_down ;; minikube:status) minikube_status ;;
  k3s:up) k3s_up ;;           k3s:down) k3s_down ;;    k3s:uninstall) k3s_uninstall ;;
  kind:up) kind_up ;;         kind:down) kind_down ;;
  edge-apps:up) edge_apps_up ;; edge-apps:down) edge_apps_down ;;
  breakout:up) breakout_up ;;
  monitoring:up) monitoring_up "$@" ;; monitoring:down) monitoring_down ;;
  portal:up) portal_up ;;     portal:down) portal_down ;;  portal:logs) portal_logs ;;
  status:) status ;;
  *) usage ;;
esac
