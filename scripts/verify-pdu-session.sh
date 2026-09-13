#!/usr/bin/env bash
# Phase 2 DoD: confirm the simulated UE registered and has a live PDU session
# tunnel, per PROJECT_PLAN.md Phase 2/9. Run after `docker compose up -d` in
# both core/ and ran/.
set -euo pipefail

echo "=== nr-ue registration / PDU session log (last 40 lines) ==="
docker logs --tail 40 ueransim-ue

echo
echo "=== uesimtun0 interface (inside the ueransim-ue container) ==="
if ! docker exec ueransim-ue ip addr show uesimtun0; then
  echo "FAIL: uesimtun0 does not exist yet. Check the log above for a" >&2
  echo "registration or PDU-session-establishment reject cause." >&2
  exit 1
fi

echo
echo "=== ping test through uesimtun0 (internet DNN) ==="
if docker exec ueransim-ue ping -I uesimtun0 -c 3 -W 2 8.8.8.8; then
  echo
  echo "PASS: UE registered, PDU session for 'internet' is up, and traffic"
  echo "routes out through the tunnel. Phase 2 DoD met."
else
  echo
  echo "uesimtun0 exists but ping failed. Check:" >&2
  echo "  - open5gs-upf's iptables MASQUERADE rule for INTERNET_UE_SUBNET" >&2
  echo "  - the host's own internet connectivity/firewall" >&2
  exit 1
fi
