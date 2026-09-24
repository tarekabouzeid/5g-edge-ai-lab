#!/usr/bin/env bash
# Single entrypoint for controlling every layer of this lab. Wraps the
# per-phase scripts already in core/, ran/, edge/, monitoring/ — this file
# adds no new logic of its own beyond sequencing and teardown, which those
# scripts don't otherwise provide.
#
# Usage: ./lab.sh <target> <action> [flags]
#
#   ./lab.sh core up|down|status|logs         Open5GS 5G core (Phase 1)
#   ./lab.sh ran up|down|status|logs          UERANSIM gNB+UE (Phase 2)
#   ./lab.sh k3s up|down|uninstall            Real host: K3s + GPU Operator (Phase 4)
#   ./lab.sh kind up|down                     Local dev/test: KIND, no GPU (see edge/kind/README.md)
#   ./lab.sh edge-apps up|down                gateway+ingest+vlm manifests (Phases 5/6, needs a GPU cluster)
#   ./lab.sh monitoring up|down [--no-gpu]    Prometheus+DCGM+Grafana (Phase 8)
#   ./lab.sh all up|down                      Real-host full stack: core+ran+k3s+edge-apps+monitoring
#   ./lab.sh portal up|down|logs              Lab portal: mission-control UI at http://localhost:8090
#   ./lab.sh status                           Summary across every layer
#
# 'down' is always non-destructive (stops/removes what 'up' created, keeps
# data — MongoDB's volume, K3s itself). Use 'k3s uninstall' to actually
# remove K3s from the host.
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,21p' "$0" | sed 's/^# \?//'; exit 1; }

core_up()   { (cd core && docker compose --env-file ../.env up -d) && ./scripts/provision-subscriber.sh; }
core_down() { (cd core && docker compose --env-file ../.env down); }
core_status() { (cd core && docker compose ps); }
core_logs() { (cd core && docker compose logs -f "$@"); }

ran_up()   { (cd ran && docker compose --env-file ../.env up -d) && ./scripts/verify-pdu-session.sh; }
ran_down() { (cd ran && docker compose --env-file ../.env down); }
ran_status() { (cd ran && docker compose ps); }
ran_logs() { (cd ran && docker compose logs -f "$@"); }

k3s_up()        { ./edge/k3s-install.sh && ./edge/install-gpu-operator.sh; }
k3s_down()      { echo "Stopping the k3s service (non-destructive — cluster state is kept; 'sudo systemctl start k3s' resumes it)."
                   sudo systemctl stop k3s; }
k3s_uninstall() { echo "This removes K3s entirely from this host (destructive)."; read -rp "Type 'yes' to continue: " c
                   [ "$c" = "yes" ] || { echo "Aborted."; exit 1; }
                   sudo /usr/local/bin/k3s-uninstall.sh; }

kind_up()   { ./edge/kind/kind-up.sh; }
kind_down() { ./edge/kind/kind-down.sh; }

edge_apps_up()   { kubectl apply -f edge/manifests/gateway.yaml -f edge/manifests/ingest-deployment.yaml
                    mkdir -p /opt/edge-lab/hf-cache 2>/dev/null || sudo mkdir -p /opt/edge-lab/hf-cache
                    kubectl apply -f edge/manifests/vlm-deployment.yaml
                    kubectl wait --for=condition=Available deployment/edge-gateway deployment/edge-ingest --timeout=180s; }
edge_apps_down() { kubectl delete -f edge/manifests/vlm-deployment.yaml -f edge/manifests/ingest-deployment.yaml \
                     -f edge/manifests/gateway.yaml --ignore-not-found; }

monitoring_up()   { ./monitoring/deploy.sh "$@"; }
monitoring_down() { kubectl delete -f monitoring/manifests/grafana.yaml -f monitoring/manifests/prometheus.yaml \
                       -f monitoring/manifests/dcgm-exporter.yaml --ignore-not-found
                     kubectl delete configmap grafana-dashboard-gpu-pipeline --ignore-not-found
                     kubectl delete secret grafana-admin --ignore-not-found; }

portal_up()   { mkdir -p demo-media
                docker compose -f portal/docker-compose.yml --env-file .env up -d --build
                echo "Lab portal: http://localhost:8090"; }
portal_down() { docker compose -f portal/docker-compose.yml --env-file .env down; }
portal_logs() { docker compose -f portal/docker-compose.yml --env-file .env logs -f; }

status() {
  echo "=== core (Open5GS) ==="; (cd core && docker compose ps 2>/dev/null) || echo "not running"
  echo; echo "=== ran (UERANSIM) ==="; (cd ran && docker compose ps 2>/dev/null) || echo "not running"
  echo; echo "=== kubectl context: $(kubectl config current-context 2>/dev/null || echo none) ==="
  kubectl get pods -A 2>/dev/null || echo "no cluster reachable"
}

[ -f .env ] || { echo "No .env found — copy .env.example to .env first."; exit 1; }

target="${1:-}"; action="${2:-}"
if [ "$#" -ge 2 ]; then shift 2; elif [ "$#" -ge 1 ]; then shift 1; fi

case "${target}:${action}" in
  core:up) core_up ;;         core:down) core_down ;;
  core:status) core_status ;; core:logs) core_logs "$@" ;;
  ran:up) ran_up ;;           ran:down) ran_down ;;
  ran:status) ran_status ;;   ran:logs) ran_logs "$@" ;;
  k3s:up) k3s_up ;;           k3s:down) k3s_down ;;    k3s:uninstall) k3s_uninstall ;;
  kind:up) kind_up ;;         kind:down) kind_down ;;
  edge-apps:up) edge_apps_up ;; edge-apps:down) edge_apps_down ;;
  monitoring:up) monitoring_up "$@" ;; monitoring:down) monitoring_down ;;
  portal:up) portal_up ;;     portal:down) portal_down ;;  portal:logs) portal_logs ;;
  all:up) core_up; ran_up; k3s_up; edge_apps_up; monitoring_up ;;
  all:down) monitoring_down; edge_apps_down; k3s_down; ran_down; core_down ;;
  status:) status ;;
  *) usage ;;
esac
