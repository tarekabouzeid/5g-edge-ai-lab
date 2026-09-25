#!/usr/bin/env bash
# Phase 3/7 local breakout for the minikube (docker driver) edge cluster.
# No sudo needed.
#
# minikube's NodePorts live on the minikube node container's IP, on its own
# docker network, not on the host. Instead of routing the edge DNN through
# the host (needs sudo + cross-bridge forwarding), attach the UPF directly to
# the minikube network and give the node a return route to the UE subnet via
# the UPF. Traffic stays un-NAT'd end to end, so the gateway sees the UE's
# real 10.47.x.x address.
#
# Runtime state only — re-run after restarting minikube, the UPF, or the UE.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi
EDGE_UE_SUBNET="${EDGE_UE_SUBNET:-10.47.0.0/16}"

docker network connect minikube open5gs-upf 2>/dev/null || true
UPF_MK_IP=$(docker inspect open5gs-upf --format '{{(index .NetworkSettings.Networks "minikube").IPAddress}}')
NODE_IP=$(minikube ip)

minikube ssh -- sudo ip route replace "${EDGE_UE_SUBNET}" via "${UPF_MK_IP}"
# The uesimtunN <-> DNN mapping depends on which PDU session finishes first
# at attach time, so pick the edge tunnel by its subnet, not its name.
EDGE_PREFIX="${EDGE_UE_SUBNET%%.0.0/*}."
EDGE_IF=$(docker exec ueransim-ue ip -4 -o addr show | awk -v p="${EDGE_PREFIX}" '$2 ~ /^uesimtun/ && index($4, p) == 1 {print $2; exit}')
if [ -z "${EDGE_IF}" ]; then
  echo "No UE tunnel in ${EDGE_UE_SUBNET} — is the edge PDU session up? (docker exec ueransim-ue ip -4 addr)" >&2
  exit 1
fi
docker exec ueransim-ue ip route replace "${NODE_IP}/32" dev "${EDGE_IF}"

echo "UPF on minikube network: ${UPF_MK_IP}"
echo "minikube node: $(minikube ssh -- ip route show "${EDGE_UE_SUBNET}" | tr -d '\r')"
echo "UE: $(docker exec ueransim-ue ip route get "${NODE_IP}" | head -1)"
echo "Stream target from inside the UE: rtsp://${NODE_IP}:30554/stream"
