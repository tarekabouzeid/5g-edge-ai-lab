#!/usr/bin/env bash
# Edge credentials — this script plays the operator's provisioning system
# (docs/security.md). In a real deployment the UE's certificate and the
# edge's TLS identity are provided out of band; here they are generated
# once into .edge-pki/ (git-ignored) and pushed where they belong.
#
#   ./scripts/edge-pki.sh init            CA, edge server cert, per-client certs, JWT signing key
#   ./scripts/edge-pki.sh apply           load them into the cluster (Secrets/ConfigMaps)
#   ./scripts/edge-pki.sh provision-ues   copy each phone's credentials + EEC into its container
#   ./scripts/edge-pki.sh revoke <id>     revoke a client: CRL at Envoy, no new tokens, live sessions kicked
#   ./scripts/edge-pki.sh restore <id>    re-issue a fresh certificate and lift the revocation
#
# Idempotent: init keeps existing material (delete .edge-pki/ to start over).
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }

PKI=.edge-pki
TLS_NAME="${EDGE_TLS_NAME:-edge.lab}"
NODE_IP="${EDGE_NODE_IP:-$(minikube ip 2>/dev/null || echo 192.168.49.2)}"
CENTRAL_IP="${CENTRAL_BIND_IP:-10.10.0.1}"
CERT_DAYS=825

# Clients authenticated by certificate (RFC 8705 tls_client_auth), as
# "client_id:GPSI:container" — container empty for non-phone clients.
# The authorization side (scopes, enabled) is in edge/authz/policy.yaml.
CLIENTS=(
  "eec-ue1:msisdn-999700000001:ueransim-ue"
  "eec-ue2:msisdn-999700000002:ueransim-ue2"
  "lab-portal::"
)

ca_conf() {
  cat > "${PKI}/ca/openssl.cnf" <<EOF
[ ca ]
default_ca = lab
[ lab ]
dir = ${PKI}/ca
database = \$dir/index.txt
new_certs_dir = \$dir/issued
serial = \$dir/serial
crlnumber = \$dir/crlnumber
certificate = \$dir/ca.crt
private_key = \$dir/ca.key
default_md = sha256
default_crl_days = 365
policy = any
unique_subject = no
[ any ]
commonName = supplied
organizationName = optional
EOF
}

new_ec_key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; chmod 600 "$1"; }

# sign <csr> <crt> <extensions...>
sign() {
  local csr=$1 crt=$2; shift 2
  local ext; ext=$(mktemp)
  printf '%s\n' "$@" > "${ext}"
  openssl ca -batch -config "${PKI}/ca/openssl.cnf" -days "${CERT_DAYS}" -notext \
    -in "${csr}" -out "${crt}" -extfile "${ext}" 2>/dev/null
  rm -f "${ext}"
}

issue_client() {
  local id=$1 gpsi=$2 key="${PKI}/clients/$1.key" csr="${PKI}/clients/$1.csr"
  new_ec_key "${key}"
  openssl req -new -key "${key}" -subj "/O=5G Edge AI Lab/CN=${id}" -out "${csr}" 2>/dev/null
  local san="URI:urn:edge-lab:eec:${id}"
  [ -n "${gpsi}" ] && san="${san},URI:urn:edge-lab:gpsi:${gpsi}"
  sign "${csr}" "${PKI}/clients/${id}.crt" \
    "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=clientAuth" "subjectAltName=${san}"
  rm -f "${csr}"
  echo "Issued client certificate for ${id}"
}

gen_crl() {
  openssl ca -gencrl -config "${PKI}/ca/openssl.cnf" -out "${PKI}/ca/ca.crl" 2>/dev/null
}

init() {
  mkdir -p "${PKI}"/{ca/issued,server,clients,jwt}
  chmod 700 "${PKI}"
  if [ ! -f "${PKI}/ca/ca.crt" ]; then
    ca_conf
    : > "${PKI}/ca/index.txt"; echo 1000 > "${PKI}/ca/serial"; echo 1000 > "${PKI}/ca/crlnumber"
    new_ec_key "${PKI}/ca/ca.key"
    openssl req -x509 -new -key "${PKI}/ca/ca.key" -days 3650 -subj "/O=5G Edge AI Lab/CN=Edge Lab Operator CA" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -out "${PKI}/ca/ca.crt"
    echo "Created operator CA"
  fi
  # The edge's TLS identity: one name (edge.lab) that phones verify, valid on
  # the node IP and on the central-cloud relay's address.
  if [ ! -f "${PKI}/server/edge.crt" ]; then
    new_ec_key "${PKI}/server/edge.key"
    openssl req -new -key "${PKI}/server/edge.key" -subj "/O=5G Edge AI Lab/CN=${TLS_NAME}" -out "${PKI}/server/edge.csr" 2>/dev/null
    sign "${PKI}/server/edge.csr" "${PKI}/server/edge.crt" \
      "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
      "extendedKeyUsage=serverAuth" "subjectAltName=DNS:${TLS_NAME},IP:${NODE_IP},IP:${CENTRAL_IP}"
    rm -f "${PKI}/server/edge.csr"
    echo "Issued edge server certificate (${TLS_NAME}, ${NODE_IP}, ${CENTRAL_IP})"
  fi
  local entry id rest gpsi
  for entry in "${CLIENTS[@]}"; do
    id=${entry%%:*}; rest=${entry#*:}; gpsi=${rest%%:*}
    [ -f "${PKI}/clients/${id}.crt" ] || issue_client "${id}" "${gpsi}"
  done
  # Token-signing key for edge-authz (RS256) and its public JWKS, which
  # Envoy (localJWKS), mediamtx and edge-ingest use to verify tokens.
  if [ ! -f "${PKI}/jwt/signing.pem" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${PKI}/jwt/signing.pem" 2>/dev/null
    chmod 600 "${PKI}/jwt/signing.pem"
    python3 - "${PKI}/jwt" <<'EOF'
import base64, hashlib, json, subprocess, sys
d = sys.argv[1]
mod = subprocess.check_output(["openssl", "rsa", "-in", f"{d}/signing.pem", "-noout", "-modulus"], text=True)
n = bytes.fromhex(mod.strip().split("=", 1)[1])
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
jwk = {"kty": "RSA", "alg": "RS256", "use": "sig", "n": b64(n), "e": b64((65537).to_bytes(3, "big"))}
# RFC 7638 thumbprint as the key id
jwk["kid"] = b64(hashlib.sha256(json.dumps({k: jwk[k] for k in ("e", "kty", "n")}, separators=(",", ":"), sort_keys=True).encode()).digest())
open(f"{d}/jwks.json", "w").write(json.dumps({"keys": [jwk]}))
open(f"{d}/kid", "w").write(jwk["kid"])
EOF
    echo "Created token-signing key (kid $(cat "${PKI}/jwt/kid"))"
  fi
  [ -f "${PKI}/ca/ca.crl" ] || gen_crl
}

apply() {
  init
  kubectl create secret tls edge-tls --cert="${PKI}/server/edge.crt" --key="${PKI}/server/edge.key" \
    --dry-run=client -o yaml | kubectl apply -f -
  # Envoy expects the CA under "ca.crt", the CRL under "ca.crl" and the
  # JWKS under "jwks".
  kubectl create configmap edge-client-ca --from-file=ca.crt="${PKI}/ca/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create configmap edge-crl --from-file=ca.crl="${PKI}/ca/ca.crl" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create configmap edge-jwks --from-file=jwks="${PKI}/jwt/jwks.json" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic edge-authz-signing --from-file=signing.pem="${PKI}/jwt/signing.pem" \
    --from-file=kid="${PKI}/jwt/kid" --dry-run=client -o yaml | kubectl apply -f -
  # Revoked client ids (persisted; edge-authz refuses them tokens).
  kubectl get configmap edge-authz-revoked >/dev/null 2>&1 || \
    kubectl create configmap edge-authz-revoked --from-literal=revoked=""
}

# The phone's provisioning profile: what the operator gives the device so
# its EEC can reach and authenticate to the edge.
provision_ues() {
  local entry id rest gpsi ctr
  for entry in "${CLIENTS[@]}"; do
    id=${entry%%:*}; rest=${entry#*:}; gpsi=${rest%%:*}; ctr=${rest#*:}
    [ -n "${ctr}" ] || continue
    if ! docker inspect -f '{{.State.Running}}' "${ctr}" 2>/dev/null | grep -q true; then
      echo "Skipping ${id}: container ${ctr} isn't running"; continue
    fi
    docker exec "${ctr}" mkdir -p /etc/edge
    docker cp "${PKI}/clients/${id}.crt" "${ctr}:/etc/edge/client.crt"
    docker cp "${PKI}/clients/${id}.key" "${ctr}:/etc/edge/client.key"
    docker cp "${PKI}/ca/ca.crt" "${ctr}:/etc/edge/ca.crt"
    docker cp ran/edge-eec.sh "${ctr}:/etc/edge/edge-eec.sh"
    docker exec -i "${ctr}" sh -c 'cat > /etc/edge/profile.env' <<EOF
# Edge provisioning profile for ${id} (GPSI ${gpsi}) — written by scripts/edge-pki.sh
CLIENT_ID=${id}
EDGE_TLS_NAME=${TLS_NAME}
TOKEN_URL=https://${NODE_IP}:${EDGE_HTTPS_NODEPORT:-30443}/token
EDGE_RTSPS=${NODE_IP}:${EDGE_RTSPS_NODEPORT:-30322}
RTSP_PATH=ue/${id}
EOF
    docker exec "${ctr}" chmod 600 /etc/edge/client.key
    docker exec "${ctr}" chmod 755 /etc/edge/edge-eec.sh
    echo "Provisioned ${id} into ${ctr}"
  done
}

authz_admin() {
  kubectl exec deploy/edge-authz -- python /app/admin.py "$@"
}

set_revoked() {  # set_revoked <id> <add|remove>
  local cur
  cur=$(kubectl get configmap edge-authz-revoked -o jsonpath='{.data.revoked}' 2>/dev/null || true)
  cur=$(python3 -c '
import sys
ids = {x for x in sys.argv[1].split(",") if x}
(ids.add if sys.argv[3] == "add" else ids.discard)(sys.argv[2])
print(",".join(sorted(ids)))' "${cur}" "$1" "$2")
  kubectl create configmap edge-authz-revoked --from-literal=revoked="${cur}" --dry-run=client -o yaml | kubectl apply -f -
}

revoke() {
  local id=${1:?usage: revoke <client_id>} crt="${PKI}/clients/$1.crt"
  [ -f "${crt}" ] || { echo "No certificate for ${id}" >&2; exit 1; }
  openssl ca -config "${PKI}/ca/openssl.cnf" -revoke "${crt}" 2>/dev/null || true
  gen_crl
  kubectl create configmap edge-crl --from-file=ca.crl="${PKI}/ca/ca.crl" --dry-run=client -o yaml | kubectl apply -f -
  set_revoked "${id}" add
  authz_admin revoke "${id}"   # immediate: refuse tokens + kick live sessions
  echo "Revoked ${id}: certificate on the CRL, no new tokens, live sessions closed."
}

restore() {
  local id=${1:?usage: restore <client_id>} entry gpsi=""
  for entry in "${CLIENTS[@]}"; do [ "${entry%%:*}" = "${id}" ] && { gpsi=${entry#*:}; gpsi=${gpsi%%:*}; }; done
  issue_client "${id}" "${gpsi}"     # a revoked certificate can't be un-revoked: issue a new one
  set_revoked "${id}" remove
  authz_admin restore "${id}"
  provision_ues
  echo "Restored ${id} with a new certificate."
}

case "${1:-}" in
  init) init ;;
  apply) apply ;;
  provision-ues) provision_ues ;;
  revoke) revoke "${2:-}" ;;
  restore) restore "${2:-}" ;;
  *) sed -n '6,11p' "$0" | sed 's/^# \?//'; exit 1 ;;
esac
