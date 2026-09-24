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

EDGE="${EDGE_APN:-edge}"

echo "Waiting for MongoDB ..."
for _ in $(seq 60); do
  docker exec open5gs-mongodb mongosh --quiet --eval "db.runCommand({ping: 1}).ok" 2>/dev/null | grep -q 1 && break
  sleep 2
done

# Idempotent: dbctl rejects an IMSI that already exists, so only add when absent.
if [ "$(docker exec open5gs-mongodb mongosh open5gs --quiet --eval "db.subscribers.countDocuments({imsi: '${IMSI}'})")" = "0" ]; then
  echo "Provisioning IMSI=${IMSI} APN=${APN} via gradiant/open5gs-dbctl ..."
  docker run --rm --network open5gscore \
    -e DB_URI="mongodb://open5gs-mongodb/open5gs" \
    "gradiant/open5gs-dbctl:${DBCTL_IMAGE_TAG:-0.10.3}" \
    "open5gs-dbctl add_ue_with_apn ${IMSI} ${KEY} ${OPC} ${APN}"
else
  echo "IMSI=${IMSI} already provisioned."
fi

# Second session for the local-breakout 'edge' DNN (Phase 3). dbctl only
# creates one DNN per subscriber, so clone the first session's QoS/AMBR
# settings under the edge DNN name — the same document the WebUI's
# "add session" produces.
echo "Ensuring the subscriber also has the '${EDGE}' DNN session ..."
docker exec open5gs-mongodb mongosh open5gs --quiet --eval "
  const s = db.subscribers.findOne({imsi: '${IMSI}'});
  const sessions = s.slice[0].session;
  if (sessions.some(x => x.name === '${EDGE}')) {
    print('  already present');
  } else {
    const edge = Object.assign({}, sessions[0], {name: '${EDGE}', _id: new ObjectId()});
    db.subscribers.updateOne({imsi: '${IMSI}'}, {\$push: {'slice.0.session': edge}});
    print('  added');
  }"

echo
echo "Subscriber as stored (DNNs per slice):"
docker exec open5gs-mongodb mongosh open5gs --quiet --eval \
  "const s = db.subscribers.findOne({imsi: '${IMSI}'}); printjson(s.slice.map(x => ({sst: x.sst, dnns: x.session.map(y => y.name)})))"

echo
echo "Phase 1 subscriber-provisioning DoD is met if both '${APN}' and '${EDGE}' are listed."
