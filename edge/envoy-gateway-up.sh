#!/usr/bin/env bash
# Installs Envoy Gateway (the controller behind edge/manifests/edge-envoy.yaml)
# onto the current cluster: the pinned release's install.yaml, which carries
# the Gateway API CRDs (incl. TCPRoute) and Envoy Gateway's own. Server-side
# apply: the CRDs are too large for client-side apply's annotation.
# Idempotent. Version: ENVOY_GATEWAY_VERSION in .env.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; source .env; set +a; }
VERSION="${ENVOY_GATEWAY_VERSION:-v1.9.3}"

echo "Installing Envoy Gateway ${VERSION} ..."
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/envoyproxy/gateway/releases/download/${VERSION}/install.yaml" >/dev/null
kubectl wait --for=condition=Available --timeout=300s -n envoy-gateway-system deployment/envoy-gateway
echo "Envoy Gateway ${VERSION} ready."
