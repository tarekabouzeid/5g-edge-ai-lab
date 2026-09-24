#!/usr/bin/env bash
# Phase 2 DoD: the simulated UE registered and has live PDU sessions for both
# DNNs, per PROJECT_PLAN.md Phase 2/9. Run after `docker compose up -d` in
# both core/ and ran/ (./lab.sh ran up does this).
#
# Tunnels are identified by subnet, not name: which uesimtunN gets which DNN
# depends on which PDU session completes first at attach time, and flips
# between attaches.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi
INTERNET_PREFIX="${INTERNET_UE_SUBNET:-10.45.0.0/16}"; INTERNET_PREFIX="${INTERNET_PREFIX%%.0.0/*}."
EDGE_PREFIX="${EDGE_UE_SUBNET:-10.47.0.0/16}"; EDGE_PREFIX="${EDGE_PREFIX%%.0.0/*}."

tunnel_for() {
  docker exec ueransim-ue ip -4 -o addr show 2>/dev/null \
    | awk -v p="$1" '$2 ~ /^uesimtun/ && index($4, p) == 1 {print $2; exit}'
}

echo "Waiting for the UE to register and bring up both PDU sessions ..."
for _ in $(seq 30); do
  INET_IF=$(tunnel_for "${INTERNET_PREFIX}"); EDGE_IF=$(tunnel_for "${EDGE_PREFIX}")
  [ -n "${INET_IF}" ] && [ -n "${EDGE_IF}" ] && break
  sleep 2
done

echo
echo "=== UE tunnels ==="
docker exec ueransim-ue ip -4 -o addr show | grep uesimtun || true

if [ -z "${INET_IF:-}" ] || [ -z "${EDGE_IF:-}" ]; then
  echo
  echo "FAIL: expected tunnels in ${INTERNET_PREFIX}x and ${EDGE_PREFIX}x. Last UE log lines:" >&2
  docker logs --tail 30 ueransim-ue >&2
  echo "Check the subscriber has both DNNs (./scripts/provision-subscriber.sh) and the core is healthy." >&2
  exit 1
fi

echo
echo "=== ping 8.8.8.8 through ${INET_IF} (internet DNN, NAT'd at the UPF) ==="
if docker exec ueransim-ue ping -I "${INET_IF}" -c 3 -W 2 8.8.8.8; then
  echo
  echo "PASS: UE registered; internet (${INET_IF}) and edge (${EDGE_IF}) PDU sessions are up,"
  echo "and internet traffic routes out through the tunnel. Phase 2 DoD met."
else
  echo
  echo "${INET_IF} exists but ping failed. Check:" >&2
  echo "  - open5gs-upf's iptables MASQUERADE rule for INTERNET_UE_SUBNET" >&2
  echo "  - the host's own internet connectivity/firewall" >&2
  exit 1
fi
