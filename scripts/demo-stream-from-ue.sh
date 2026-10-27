#!/usr/bin/env bash
# Presentation helper: stream a video *from inside a simulated phone* through
# the edge DNN (UE edge tunnel -> gNB -> UPF, un-NAT'd) into the edge, looping
# forever. The phone does it the secure way (docs/security.md): its EEC gets
# a token with its own certificate and streams over mutual TLS to its own
# path, ue/<EEC ID>.
#
# For UE 1, if the lab portal (http://localhost:8090) is running it owns the
# phone's camera — this script then just asks the portal to start/stop it.
#
# Usage: ./scripts/demo-stream-from-ue.sh [video-file] [ue-container]
#          video default demo-media/traffic.mp4 (test pattern if missing),
#          container default ueransim-ue (UE 2: ueransim-ue2)
#        ./scripts/demo-stream-from-ue.sh stop [ue-container]
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${1:-}" = "stop" ]; then ACTION=stop; UE="${2:-ueransim-ue}"; else ACTION=start; UE="${2:-ueransim-ue}"; fi
SOURCE="${1:-demo-media/traffic.mp4}"

PORTAL="http://localhost:8090"
if [ "${UE}" = ueransim-ue ] && curl -sf -m 2 "${PORTAL}/api/state" >/dev/null; then
  if [ "${ACTION}" = stop ]; then
    curl -sf -XPOST "${PORTAL}/api/ue/camera" -H 'content-type: application/json' -d '{"on":false}' >/dev/null
    echo "Asked the lab portal to stop the phone's camera."
    exit 0
  fi
  case "${SOURCE}" in
    demo-media/*) VIDEO=$(basename "${SOURCE}") ;;
    *) echo "With the portal running, pick a video in demo-media/ (or upload it in the portal UI)." >&2; exit 1 ;;
  esac
  curl -sf -XPOST "${PORTAL}/api/ue/camera" -H 'content-type: application/json' -d "{\"on\":true,\"video\":\"${VIDEO}\"}" >/dev/null
  echo "Asked the lab portal to stream ${VIDEO} from the phone — watch it at ${PORTAL}"
  exit 0
fi

stop_stream() { docker exec "${UE}" sh -c 'pkill -f "[e]dge-eec.sh" || true'; }

if [ "${ACTION}" = stop ]; then
  stop_stream
  echo "Stopped ${UE}'s stream."
  exit 0
fi

NODE_IP=$(minikube ip)
./edge/setup-minikube-breakout.sh >/dev/null
./scripts/edge-pki.sh provision-ues >/dev/null

if ! docker exec "${UE}" sh -c 'command -v ffmpeg && command -v socat' >/dev/null 2>&1; then
  echo "Installing ffmpeg + socat inside ${UE} (one-off, lost if the container is recreated)..."
  docker exec "${UE}" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ffmpeg socat >/dev/null'
fi

stop_stream
if [ -f "${SOURCE}" ]; then
  docker cp "${SOURCE}" "${UE}:/tmp/demo-input.mp4"
  INPUT=/tmp/demo-input.mp4
  echo "Streaming ${SOURCE} from ${UE} (looping)..."
else
  INPUT=test-pattern
  echo "No ${SOURCE} — streaming a test pattern from ${UE} instead..."
fi

docker exec -d "${UE}" sh -c "/etc/edge/edge-eec.sh ${NODE_IP}:30322 ${INPUT} > /tmp/demo-eec.log 2>&1"

ID=$(docker exec "${UE}" sh -c '. /etc/edge/profile.env && echo "${CLIENT_ID}"')
echo "${UE} (${ID}) streams over mutual TLS to rtsps://${NODE_IP}:30322/ue/${ID}. Stop with: $0 stop ${UE}"
echo "Its EEC log: docker exec ${UE} cat /tmp/demo-eec.log"
echo "Prove the 5G path live:  docker exec open5gs-upf tcpdump -i ogstun2 -n"
