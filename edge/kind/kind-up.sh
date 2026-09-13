#!/usr/bin/env bash
# Local dev/test path: bring up a KIND cluster and the CPU-compatible subset
# of the edge stack (gateway + ingest + monitoring, no VLM/GPU). See
# edge/kind/README.md for exactly what this proves and doesn't.
set -euo pipefail

cd "$(dirname "$0")/../.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-edge-ai-lab}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"

command -v kind >/dev/null || {
  echo "kind not found. Install it: https://kind.sigs.k8s.io/docs/user/quick-start/#installation" >&2
  exit 1
}

echo "Creating KIND cluster '${KIND_CLUSTER_NAME}'..."
IMAGE_ARGS=()
if [ -n "${KIND_NODE_IMAGE}" ]; then
  IMAGE_ARGS=(--image "${KIND_NODE_IMAGE}")
fi
kind create cluster --name "${KIND_CLUSTER_NAME}" \
  --config edge/kind/kind-config.yaml "${IMAGE_ARGS[@]}"

kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null

echo
echo "Building and loading the ingest image into the cluster..."
docker build -t edge-ingest:local edge/ingest
kind load docker-image edge-ingest:local --name "${KIND_CLUSTER_NAME}"

echo
echo "Applying gateway + ingest (CPU mode)..."
kubectl apply -f edge/manifests/gateway.yaml
kubectl apply -f edge/kind/ingest-deployment.kind.yaml
kubectl wait --for=condition=Available deployment/edge-gateway --timeout=120s
kubectl wait --for=condition=Available deployment/edge-ingest --timeout=180s

echo
echo "Deploying monitoring (no GPU)..."
./monitoring/deploy.sh --no-gpu

cat <<EOF

KIND cluster '${KIND_CLUSTER_NAME}' is up:
  RTSP gateway : rtsp://localhost:30554/stream
  edge-ingest  : http://localhost:30080/status
  Grafana      : http://localhost:30300  (admin / \$GRAFANA_ADMIN_PASSWORD)

Try it: EDGE_NODE_IP=localhost ./scripts/stream-test-video.sh
(the gateway/ingest NodePorts match the real K3s setup, so
scripts/stream-test-video.sh works unchanged against either backend)

Not available in this mode (see edge/kind/README.md): real GPU inference,
the vlm Deployment, and DCGM GPU metrics — those need the real
edge/k3s-install.sh + install-gpu-operator.sh path on a GPU host.

Tear down: ./edge/kind/kind-down.sh
EOF
