#!/usr/bin/env bash
# Phase 1 DoD: provision a test subscriber in the UDM/UDR (MongoDB-backed) database.
#
# Uses gradiant/open5gs-dbctl, a dedicated image that packages upstream
# open5gs's own misc/db/open5gs-dbctl script (source:
# github.com/Gradiant/5g-images/tree/master/images/open5gs-dbctl), run as a
# one-shot container on the core's network — NOT `docker exec` into the
# open5gs-webui container, which does not actually contain this script
# (that was a wrong assumption in an earlier version of this file; the
# webui image only serves the Node.js web UI, confirmed against its own
# Dockerfile source). Using the real upstream script instead of a
# hand-maintained Mongo insert means the subscriber document can't drift
# from whatever schema this Open5GS version actually expects.
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

echo "Provisioning IMSI=${IMSI} APN=${APN} via gradiant/open5gs-dbctl ..."
docker run --rm --network open5gscore \
  -e DB_URI="mongodb://open5gs-mongodb/open5gs" \
  "gradiant/open5gs-dbctl:${DBCTL_IMAGE_TAG:-0.10.3}" \
  "open5gs-dbctl add_ue_with_apn ${IMSI} ${KEY} ${OPC} ${APN}"

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
