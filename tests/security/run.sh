#!/usr/bin/env bash
# Edge security tests that need no cluster (docs/security.md) — run by CI's
# lint job and locally:  pip install -r edge/authz/requirements.txt \
#   httpx prometheus-client && tests/security/run.sh
# Generates a throwaway PKI with the real scripts/edge-pki.sh, then checks
# edge-authz, edge-ingest's token checks, and (if socat is installed) the
# phone's mutual-TLS leg including CRL revocation.
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/scripts" "${WORK}/ran"
cp scripts/edge-pki.sh "${WORK}/scripts/"
cp ran/edge-eec.sh "${WORK}/ran/"
printf 'EDGE_NODE_IP=192.168.49.2\n' > "${WORK}/.env"
(cd "${WORK}" && ./scripts/edge-pki.sh init >/dev/null)

python3 tests/security/test_authz.py "${PWD}" "${WORK}"
python3 tests/security/test_ingest_auth.py "${PWD}" "${WORK}"
if command -v socat >/dev/null; then
  tests/security/test_tls_leg.sh "${WORK}"
else
  echo "SKIP phone TLS leg (socat not installed)"
fi
