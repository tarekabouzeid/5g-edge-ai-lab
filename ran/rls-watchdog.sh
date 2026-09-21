#!/usr/bin/env bash
# Works around a confirmed upstream UERANSIM defect (gradiant/ueransim
# 3.2.8 AND 3.3.0, reproduced on this host) where the UE's RLS data path
# periodically stalls for several seconds and, on reselection, sometimes
# never recovers (AMF context loss — matches
# https://github.com/aligungr/UERANSIM/issues/757, an open upstream issue
# with no fix as of 2026-09-20). Root-caused via packet capture + strace on
# this host: the tunnel forwards data correctly immediately after every
# fresh UE attach, and only degrades afterward — so periodically detecting
# a stalled tunnel and restarting gNB+UE (which re-attach cleanly) keeps
# the data path continuously usable. This is an operational workaround for
# an upstream bug, not a fix to this project's own config.
#
# Usage: ./ran/rls-watchdog.sh [check_interval_seconds]
#   Runs until killed. Logs every restart it performs.
set -euo pipefail

cd "$(dirname "$0")/.."
INTERVAL="${1:-5}"

echo "[rls-watchdog] starting, checking every ${INTERVAL}s (see docs/phase-notes/phase-2.md 'Known risks' for why this exists)"

while true; do
  # 3 attempts, not 1: a single missed packet during a real reconnect
  # window (jittery but recovering) shouldn't count as failure — only
  # treat it as down when every attempt in the batch fails.
  #
  # Capture output into a variable rather than piping straight into grep:
  # `ping` itself exits non-zero on packet loss, and with `pipefail` set,
  # `cmd | grep -q pattern` reports overall failure whenever `cmd` exits
  # non-zero even if grep DID match — inverting exactly the case this
  # script cares about. `PING_OUT=$(cmd) || true` sidesteps that.
  PING_OUT=$(docker exec ueransim-ue ping -I uesimtun0 -c3 -W2 8.8.8.8 2>&1) || true
  if grep -q ", 0 received" <<<"${PING_OUT}"; then
    # Restarting the UE alone is not enough: the gNB accumulates broken
    # internal UE/PDU-session tracking state across repeated churn (ghost
    # UE contexts — confirmed via `nr-cli <gnb> -e ue-list` showing many
    # stale entries with amf-ngap-id: -1), and a UE restart against an
    # already-degraded gNB often can't even find a cell again. Restart both
    # together, gNB first, for a genuinely clean slate each cycle.
    echo "[rls-watchdog] $(date -Iseconds) tunnel check failed — restarting gNB+UE"
    docker restart ueransim-gnb >/dev/null 2>&1 || true
    sleep 5
    docker restart ueransim-ue >/dev/null 2>&1 || true
    sleep 4   # give it time to re-register before the next check
  fi
  sleep "${INTERVAL}"
done
