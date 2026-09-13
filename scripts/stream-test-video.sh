#!/usr/bin/env bash
# Phase 5/7: push a test video into the edge cluster's RTSP gateway.
#
# By default generates a synthetic test pattern with ffmpeg (no external
# video asset needed) and streams it over RTSP to edge-gateway's NodePort.
# Pass a real file path as $1 to stream that instead.
#
# Phase 7 (full end-to-end): running this from the host, as below, only
# exercises Phase 5 in isolation. To genuinely transit uesimtun1 -> gNB ->
# UPF -> K3s, the equivalent ffmpeg command needs to run *inside* the
# ueransim-ue container with a host route forcing it onto uesimtun1 first —
# see docs/phase-notes/phase-7.md for the exact steps (a plain
# `-bind_address` on the UE's tunnel IP is not reliable for this).
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi

EDGE_NODE_IP="${EDGE_NODE_IP:?set EDGE_NODE_IP in .env to the K3s nodes reachable IP}"
RTSP_TARGET="rtsp://${EDGE_NODE_IP}:30554/stream"
SOURCE="${1:-}"
DURATION="${2:-60}"

echo "Streaming to ${RTSP_TARGET} for ${DURATION}s..."

if [ -n "${SOURCE}" ]; then
  ffmpeg -re -stream_loop -1 -i "${SOURCE}" -t "${DURATION}" \
    -c:v libx264 -preset veryfast -f rtsp -rtsp_transport tcp "${RTSP_TARGET}"
else
  echo "No source file given — generating a synthetic test pattern instead."
  ffmpeg -re -f lavfi -i "testsrc=size=1280x720:rate=30" \
    -t "${DURATION}" -c:v libx264 -preset veryfast \
    -f rtsp -rtsp_transport tcp "${RTSP_TARGET}"
fi

echo
echo "Stream finished. Check ingestion results with:"
echo "  kubectl logs -l app=edge-ingest --tail=50"
echo "  curl http://\${EDGE_NODE_IP}:<edge-ingest NodePort or port-forward>/status"
