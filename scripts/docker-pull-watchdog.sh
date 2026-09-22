#!/usr/bin/env bash
# Works around a real, reproducible network issue seen on this WSL2 host:
# a long-lived docker pull/build image-layer download starts at a normal
# ~1-2MB/s and reliably degrades to a near-total stall (~20-200KB/s) after
# roughly 25-30 minutes of sustained transfer — confirmed NOT a registry
# rate-limit (Docker Hub's x-ratelimit-remaining header stayed at 100/100)
# and NOT a general bandwidth problem (a fresh `curl` to the exact same
# blob that was stalled inside the docker pull got 1MB/s+ immediately).
# Killing and restarting the pull/build reliably restores full speed for
# another ~25-30 minutes. This script automates that cycle: it runs the
# given command in a loop, watches its own combined stdout+stderr for
# stalled byte-progress, and kills+reruns it when a stall is detected —
# repeating until the command finally exits 0.
#
# Usage: ./scripts/docker-pull-watchdog.sh <log-file> <check_interval_seconds> <stall_threshold_bytes> -- <command...>
#   e.g. ./scripts/docker-pull-watchdog.sh /tmp/ingest_build.log 60 2000000 -- \
#          docker build -t edge-ingest:local edge/ingest
#
# NOTE ON RESTART COST: docker's classic (non-BuildKit) puller does not
# resume a partially-downloaded layer — killing mid-layer restarts that
# specific layer from 0, it doesn't lose EARLIER, fully-completed layers
# (those stay cached). So a kill loses at most "the one layer currently
# in flight", not the whole build/pull. Confirmed on this host: restarting
# after killing did re-pull the same base-image layer from 0%, not from
# where a prior attempt had reached partway.
set -uo pipefail

LOG_FILE="${1:?usage: docker-pull-watchdog.sh <log-file> <interval> <threshold_bytes> -- <command...>}"
INTERVAL="${2:?}"
THRESHOLD_BYTES="${3:?}"
shift 3
if [ "${1:-}" != "--" ]; then
  echo "usage: docker-pull-watchdog.sh <log-file> <interval> <threshold_bytes> -- <command...>" >&2
  exit 2
fi
shift

total_progress_bytes() {
  # Keep only the LATEST value per unique layer digest, not a sum of every
  # repeated progress line (docker reprints the same layer's running total
  # many times/sec — summing every occurrence trivially grows over time
  # regardless of whether real transfer is happening, which made an
  # earlier version of this function useless for stall detection: it
  # reported multi-GB/min "progress" while the real transfer, checked
  # directly against the log, was stalled at <1MB/s). Matches BuildKit's
  # `#N sha256:<digest> X.XXunit / Y.YYunit Ns` format (docker build) —
  # extend the regex here if wrapping a plain `docker pull` too (its
  # classic non-BuildKit format is `<short-digest>: Downloading
  # [...] X.XXunit/Y.YYunit`, different enough to need its own pattern).
  grep -oE 'sha256:[0-9a-f]+ [0-9]+(\.[0-9]+)?(kB|MB|GB) / ' "${LOG_FILE}" 2>/dev/null \
    | awk '{
        key=$1;
        v=$2; sub(/[a-zA-Z]+$/,"",v);
        u=$2; sub(/^[0-9.]+/,"",u);
        if (u=="kB") v*=1000; else if (u=="MB") v*=1000000; else if (u=="GB") v*=1000000000;
        latest[key]=v
      } END{ sum=0; for (k in latest) sum+=latest[k]; printf "%.0f", sum }'
}

ATTEMPT=0
while true; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "[pull-watchdog] $(date -Iseconds) attempt ${ATTEMPT}: starting '$*'"
  : > "${LOG_FILE}"
  "$@" >> "${LOG_FILE}" 2>&1 &
  CMD_PID=$!

  PREV=0
  SLOW_STREAK=0
  while kill -0 "${CMD_PID}" 2>/dev/null; do
    sleep "${INTERVAL}"
    kill -0 "${CMD_PID}" 2>/dev/null || break
    CUR=$(total_progress_bytes)
    DELTA=$((CUR - PREV))
    echo "[pull-watchdog] $(date -Iseconds) delta=${DELTA} bytes over ${INTERVAL}s (total so far: ${CUR})"
    PREV="${CUR}"
    if [ "${DELTA}" -lt "${THRESHOLD_BYTES}" ]; then
      SLOW_STREAK=$((SLOW_STREAK + 1))
    else
      SLOW_STREAK=0
    fi
    if [ "${SLOW_STREAK}" -ge 2 ]; then
      echo "[pull-watchdog] $(date -Iseconds) STALL detected — killing attempt ${ATTEMPT} and retrying"
      kill "${CMD_PID}" 2>/dev/null || true
      sleep 2
      kill -9 "${CMD_PID}" 2>/dev/null || true
      break
    fi
  done

  wait "${CMD_PID}" 2>/dev/null
  RC=$?
  if [ "${SLOW_STREAK}" -lt 2 ] && [ "${RC}" -eq 0 ]; then
    echo "[pull-watchdog] $(date -Iseconds) command succeeded (exit 0) on attempt ${ATTEMPT}"
    exit 0
  fi
  echo "[pull-watchdog] $(date -Iseconds) attempt ${ATTEMPT} ended (exit ${RC}, stalled=${SLOW_STREAK}) — retrying"
done
