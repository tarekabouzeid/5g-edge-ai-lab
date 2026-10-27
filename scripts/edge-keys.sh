#!/usr/bin/env bash
# Edge API keys (see docs/security.md).
#
#   ./scripts/edge-keys.sh ensure   generate any key that is empty in .env
#   ./scripts/edge-keys.sh apply    ensure, then load them into the edge-auth
#                                   Secret on the current kubectl context
#
# Keys live only in .env (git-ignored) and the edge-auth Secret — never in a
# manifest. Idempotent: existing keys are kept. To rotate one, blank it in
# .env, re-run `apply`, then restart its consumers (docs/security.md).
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env found — copy .env.example to .env first." >&2; exit 1; }

# .env variable -> Secret key. Who holds each one is in docs/security.md.
KEYS=(
  "EDGE_UE_STREAM_KEY:ue-stream-key"
  "EDGE_INGEST_API_KEY:ingest-api-key"
  "EDGE_GATEWAY_INGEST_KEY:gateway-ingest-key"
  "EDGE_VLM_API_KEY:vlm-api-key"
)

new_key() { python3 -c 'import secrets; print(secrets.token_hex(24))'; }

ensure() {
  local entry var value
  for entry in "${KEYS[@]}"; do
    var="${entry%%:*}"
    value=$(grep -m1 -oP "^${var}=\K.*" .env || true)
    [ -n "${value}" ] && continue
    value=$(new_key)
    if grep -q "^${var}=" .env; then
      sed -i "s|^${var}=.*|${var}=${value}|" .env
    else
      [ -z "$(tail -c1 .env)" ] || echo >> .env   # don't glue onto an unterminated last line
      printf '%s=%s\n' "${var}" "${value}" >> .env
    fi
    echo "Generated ${var} in .env"
  done
  chmod 600 .env   # holds secrets: owner-only
}

apply() {
  ensure
  local entry var args=()
  for entry in "${KEYS[@]}"; do
    var="${entry%%:*}"
    args+=(--from-literal="${entry##*:}=$(grep -m1 -oP "^${var}=\K.*" .env)")
  done
  kubectl create secret generic edge-auth "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
}

case "${1:-}" in
  ensure) ensure ;;
  apply) apply ;;
  *) echo "Usage: $0 ensure|apply" >&2; exit 1 ;;
esac
