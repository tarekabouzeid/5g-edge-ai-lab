#!/usr/bin/env bash
# Phase 5: push a test video into the edge from the host — no simulated
# radio path involved (for that, use scripts/demo-stream-from-ue.sh or the
# lab portal; see docs/phase-notes/phase-7.md).
#
# The edge accepts only authenticated phones (docs/security.md), so this
# test client presents UE 1's provisioned credentials, exactly as UE 1's
# EEC would: an access token over mutual TLS, then RTSP over a mutual-TLS
# tunnel to Envoy, publishing to ue/eec-ue1. Needs ffmpeg, socat and curl
# on the host.
#
# Usage: ./scripts/stream-test-video.sh [video-file] [seconds]   (default: test pattern, 60 s)
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi
for bin in ffmpeg socat curl; do
  command -v "${bin}" >/dev/null || { echo "Missing '${bin}' on the host." >&2; exit 1; }
done

EDGE_NODE_IP="${EDGE_NODE_IP:-$(minikube ip)}"
ID=eec-ue1
PKI=.edge-pki
[ -f "${PKI}/clients/${ID}.crt" ] || { echo "No edge credentials — run ./lab.sh edge-apps up first." >&2; exit 1; }
CERT=(--cert "${PKI}/clients/${ID}.crt" --key "${PKI}/clients/${ID}.key" --cacert "${PKI}/ca/ca.crt")
SOURCE="${1:-}"
DURATION="${2:-60}"

TOKEN=$(curl -sS --fail --tlsv1.2 "${CERT[@]}" -d grant_type=client_credentials -d "client_id=${ID}" \
  "https://${EDGE_NODE_IP}:30443/token" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "${TOKEN}" ] || { echo "No access token for ${ID} (revoked?)." >&2; exit 1; }

socat TCP-LISTEN:18554,bind=127.0.0.1,reuseaddr,fork \
  "OPENSSL:${EDGE_NODE_IP}:30322,cert=${PKI}/clients/${ID}.crt,key=${PKI}/clients/${ID}.key,cafile=${PKI}/ca/ca.crt,verify=1,commonname=${EDGE_TLS_NAME:-edge.lab},openssl-min-proto-version=TLS1.2" &
TUNNEL=$!
trap 'kill ${TUNNEL} 2>/dev/null || true' EXIT
sleep 1

TARGET="rtsp://${ID}:${TOKEN}@127.0.0.1:18554/ue/${ID}"
echo "Streaming to rtsps://${EDGE_NODE_IP}:30322/ue/${ID} (as ${ID}) for ${DURATION}s..."
if [ -n "${SOURCE}" ]; then
  INPUT=(-re -stream_loop -1 -i "${SOURCE}")
else
  echo "No source file given — generating a synthetic test pattern instead."
  INPUT=(-re -f lavfi -i "testsrc=size=1280x720:rate=30")
fi
ffmpeg -loglevel error "${INPUT[@]}" -t "${DURATION}" -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -f rtsp -rtsp_transport tcp "${TARGET}"

echo
echo "Stream finished. Check ingestion results with:"
echo "  kubectl logs -l app=edge-ingest --tail=50"
