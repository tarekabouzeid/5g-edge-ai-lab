#!/usr/bin/env bash
# Downloads the sample camera clips the lab portal offers (demo-media/,
# git-ignored). Idempotent — existing files are skipped. Source: Intel's
# openly licensed sample videos for detection demos
# (https://github.com/intel-iot-devkit/sample-videos). Any other clip can be
# dropped into demo-media/ or uploaded from the portal.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p demo-media

BASE=https://github.com/intel-iot-devkit/sample-videos/raw/master
declare -A CLIPS=(
  [traffic.mp4]=person-bicycle-car-detection.mp4
  [worker-zone-detection.mp4]=worker-zone-detection.mp4
  [people-detection.mp4]=people-detection.mp4
  [car-detection.mp4]=car-detection.mp4
)
for name in "${!CLIPS[@]}"; do
  if [ -s "demo-media/${name}" ]; then
    echo "have     demo-media/${name}"
  else
    echo "fetching demo-media/${name}"
    curl -fsSL -o "demo-media/${name}.part" "${BASE}/${CLIPS[$name]}"
    mv "demo-media/${name}.part" "demo-media/${name}"
  fi
done
