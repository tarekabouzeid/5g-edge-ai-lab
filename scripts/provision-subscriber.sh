#!/usr/bin/env bash
# Phase 1 DoD: provision a test subscriber in the UDM/UDR (MongoDB-backed) database.
#
# Uses open5gs-dbctl, the tool shipped inside the open5gs-webui image, so the
# subscriber document matches whatever schema that Open5GS version expects
# instead of a hand-maintained Mongo insert that could drift from it.
#
# Usage: ./scripts/provision-subscriber.sh [imsi] [key] [opc] [apn]
# Defaults come from ../.env (copy .env.example to .env first).
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi

IMSI="${1:-${TEST_IMSI:?set TEST_IMSI in .env or pass as \$1}}"
KEY="${2:-${TEST_KEY:?set TEST_KEY in .env or pass as \$2}}"
OPC="${3:-${TEST_OPC:?set TEST_OPC in .env or pass as \$3}}"
APN="${4:-${TEST_APN:-internet}}"

echo "Provisioning IMSI=${IMSI} APN=${APN} via open5gs-webui's open5gs-dbctl ..."
# No -t: this runs unattended in CI (no TTY attached to the runner's shell
# step, where `-t` makes docker exec fail immediately) as well as
# interactively, and neither open5gs-dbctl nor mongosh needs a TTY to work.
docker exec open5gs-webui misc/db/open5gs-dbctl add_ue_with_apn "${IMSI}" "${KEY}" "${OPC}" "${APN}"

echo
echo "Verifying subscriber is present in MongoDB:"
docker exec open5gs-mongodb mongosh open5gs --quiet --eval \
  "db.subscribers.findOne({imsi: '${IMSI}'}, {imsi:1, security:1, slice:1})"

echo
echo "If this printed a document (not null), Phase 1's subscriber-provisioning"
echo "DoD is met."
echo
echo "To let this same UE also reach the 'edge' DNN (Phase 3), add a second"
echo "session via the WebUI (http://<host>:9999, default login admin/1423):"
echo "  Subscriber -> ${IMSI} -> edit -> add session -> DNN: edge, slice sst: 1"
echo "open5gs-dbctl's add_ue_with_apn only sets up one DNN per call and may"
echo "reject a second call for an IMSI that already exists, so the WebUI is"
echo "the more reliable path for the second session."
