#!/bin/sh
# The phone's edge client (EEC, 3GPP TS 23.558/33.558) — installed into each
# UE container at /etc/edge/ by scripts/edge-pki.sh provision-ues, next to
# the credentials the operator provisioned (client.crt/.key, ca.crt) and the
# profile (profile.env). See docs/security.md.
#
#   edge-eec.sh <host:port> <video file | test-pattern>
#
# 1. Gets an access token from the edge authorization server: OAuth 2.0
#    client credentials over mutual TLS, authenticated by this phone's
#    certificate (RFC 8705) — the token is bound to that certificate.
# 2. Opens a mutual-TLS tunnel to the edge's RTSPS listener at <host:port>
#    (the edge node, or the central-cloud relay), verifying the edge's
#    certificate against the operator CA and name.
# 3. Runs the camera app (AC): ffmpeg streams RTSP into the tunnel, with the
#    token as its RTSP password, to this phone's own path ue/<EEC ID>.
# Fetches a fresh token whenever the stream has to (re)connect.
set -eu

TARGET=${1:?usage: edge-eec.sh <host:port> <video file | test-pattern>}
SOURCE=${2:-test-pattern}
. /etc/edge/profile.env   # CLIENT_ID, EDGE_TLS_NAME, TOKEN_URL, RTSP_PATH
TLS="cert=/etc/edge/client.crt,key=/etc/edge/client.key,cafile=/etc/edge/ca.crt,verify=1"
LOCAL_PORT=18554

if [ "${SOURCE}" = test-pattern ]; then
  INPUT="-re -f lavfi -i testsrc2=size=1280x720:rate=25"
else
  INPUT="-re -stream_loop -1 -i ${SOURCE}"
fi

cleanup() { kill "${TUNNEL_PID:-}" "${APP_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 0' TERM INT

# The plaintext leg never leaves the phone (127.0.0.1); everything on the
# network is mutual TLS (1.2+), with the edge's identity checked.
socat "TCP-LISTEN:${LOCAL_PORT},bind=127.0.0.1,reuseaddr,fork" \
  "OPENSSL:${TARGET},${TLS},commonname=${EDGE_TLS_NAME},openssl-min-proto-version=TLS1.2" &
TUNNEL_PID=$!

while :; do
  TOKEN=$(curl -sS --fail --max-time 10 --tlsv1.2 \
    --cert /etc/edge/client.crt --key /etc/edge/client.key --cacert /etc/edge/ca.crt \
    -d grant_type=client_credentials -d "client_id=${CLIENT_ID}" "${TOKEN_URL}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p') || TOKEN=""
  if [ -z "${TOKEN}" ]; then
    echo "edge-eec: no access token for ${CLIENT_ID} (revoked, or the edge is unreachable); retrying in 5s" >&2
    sleep 5; continue
  fi
  # shellcheck disable=SC2086  # INPUT is deliberately word-split
  ffmpeg -nostdin -loglevel error ${INPUT} -an -vf 'scale=w=min(1280\,iw):h=-2' \
    -r 30 -c:v libx264 -preset veryfast -tune zerolatency -g 30 -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp "rtsp://${CLIENT_ID}:${TOKEN}@127.0.0.1:${LOCAL_PORT}/${RTSP_PATH}" &
  APP_PID=$!
  wait "${APP_PID}" || true
  echo "edge-eec: stream ended; reconnecting with a new token in 3s" >&2
  sleep 3
done
