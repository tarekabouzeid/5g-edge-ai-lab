#!/usr/bin/env bash
# Presentation helper: stream a video *from inside the simulated UE* through
# the edge DNN (uesimtun1 -> gNB -> UPF, un-NAT'd) into the minikube edge
# cluster's RTSP gateway, looping forever so the demo page stays live.
#
# Usage: ./scripts/demo-stream-from-ue.sh [video-file]   (default: demo-media/traffic.mp4,
#                                                         falls back to an ffmpeg test pattern)
#        ./scripts/demo-stream-from-ue.sh stop
set -euo pipefail

cd "$(dirname "$0")/.."

stop_stream() {
  docker exec ueransim-ue sh -c 'pkill -f "[f]fmpeg .*rtsp://" || true'
}

if [ "${1:-}" = "stop" ]; then
  stop_stream
  echo "Stopped the UE's stream."
  exit 0
fi

SOURCE="${1:-demo-media/traffic.mp4}"
NODE_IP=$(minikube ip)

./edge/setup-minikube-breakout.sh

if ! docker exec ueransim-ue which ffmpeg >/dev/null 2>&1; then
  echo "Installing ffmpeg inside the UE container (one-off, lost if the container is recreated)..."
  docker exec ueransim-ue sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ffmpeg >/dev/null'
fi

stop_stream
if [ -f "${SOURCE}" ]; then
  docker cp "${SOURCE}" ueransim-ue:/tmp/demo-input.mp4
  INPUT='-re -stream_loop -1 -i /tmp/demo-input.mp4'
  echo "Streaming ${SOURCE} from the UE (looping)..."
else
  INPUT='-re -f lavfi -i testsrc=size=1280x720:rate=30'
  echo "No ${SOURCE} — streaming an ffmpeg test pattern from the UE instead..."
fi

docker exec -d ueransim-ue sh -c "ffmpeg -nostdin ${INPUT} -an -c:v libx264 -preset veryfast -tune zerolatency -g 30 -pix_fmt yuv420p \
  -f rtsp -rtsp_transport tcp rtsp://${NODE_IP}:30554/stream > /tmp/demo-ffmpeg.log 2>&1"

echo "Streaming to rtsp://${NODE_IP}:30554/stream via uesimtun1. Stop with: $0 stop"
echo "Prove the 5G path live:  docker exec open5gs-upf tcpdump -i ogstun2 -n"
