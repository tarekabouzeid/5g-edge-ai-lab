#!/usr/bin/env bash
# Phase 3: host-side routing so the UPF's un-NAT'd 'edge' DNN subnet
# (EDGE_UE_SUBNET, default 10.47.0.0/16) can reach — and receive return
# traffic from — the K3s edge cluster running natively on this same host.
#
# Why this is needed: 10.47.0.0/16 lives on the UPF container's ogstun2 TUN
# interface, inside its own network namespace. The host only learns to route
# to it if we tell it to, via the UPF container's bridge IP (UPF_IP) which
# *is* on a network the host already has a route to (the open5gscore bridge).
# Without this, K3s Service/Pod responses to a UE's traffic have no way back.
#
# This is a design that follows directly from the Docker networking model,
# but it has not been run against a real K3s installation from this build
# session (see docs/phase-notes/phase-0.md) — verify the DoD command at the
# bottom of docs/phase-notes/phase-3.md on the real host before trusting it.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi

EDGE_UE_SUBNET="${EDGE_UE_SUBNET:?set EDGE_UE_SUBNET in .env}"
UPF_IP="${UPF_IP:?set UPF_IP in .env}"

echo "Adding host route: ${EDGE_UE_SUBNET} via ${UPF_IP}"
sudo ip route replace "${EDGE_UE_SUBNET}" via "${UPF_IP}"

echo "Allowing forwarding between the edge DNN subnet and the rest of the host"
echo "(K3s's own CNI already manages its own bridge's forwarding rules; this"
echo "only covers the docker bridge <-> host boundary)."
sudo iptables -C FORWARD -s "${EDGE_UE_SUBNET}" -j ACCEPT 2>/dev/null || \
  sudo iptables -I FORWARD -s "${EDGE_UE_SUBNET}" -j ACCEPT
sudo iptables -C FORWARD -d "${EDGE_UE_SUBNET}" -j ACCEPT 2>/dev/null || \
  sudo iptables -I FORWARD -d "${EDGE_UE_SUBNET}" -j ACCEPT

echo
echo "Route table entry:"
ip route show "${EDGE_UE_SUBNET}"
