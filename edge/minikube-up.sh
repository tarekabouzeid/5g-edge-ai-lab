#!/usr/bin/env bash
# Phase 4: the edge Kubernetes cluster as minikube on the Docker driver with
# the host GPU passed through (--gpus=nvidia.com). Verified end to end on
# WSL2 + RTX 5070 Ti; see docs/phase-notes/phase-4.md. No sudo needed.
#
# Idempotent: re-running starts a stopped cluster, leaves a running one alone,
# and rebuilds the ingest image only if its sources changed (Docker cache).
#
# Env (optional, in .env): MINIKUBE_CPUS, MINIKUBE_MEMORY (e.g. 8g).
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi

for bin in docker minikube kubectl; do
  command -v "$bin" >/dev/null || { echo "Missing '$bin' — see README 'Requirements'." >&2; exit 1; }
done
if ! docker info --format '{{json .Runtimes}}' | grep -q nvidia; then
  echo "Docker has no 'nvidia' runtime — install the NVIDIA Container Toolkit first" >&2
  echo "(README 'Running on WSL2', step 1), then re-run." >&2
  exit 1
fi

ARGS=(--driver=docker --container-runtime=docker --gpus=nvidia.com)
[ -n "${MINIKUBE_CPUS:-}" ] && ARGS+=(--cpus="${MINIKUBE_CPUS}")
[ -n "${MINIKUBE_MEMORY:-}" ] && ARGS+=(--memory="${MINIKUBE_MEMORY}")

if minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
  echo "minikube already running."
else
  echo "Starting minikube with GPU passthrough..."
  minikube start "${ARGS[@]}"
fi

echo "Waiting for the node to advertise nvidia.com/gpu..."
for _ in $(seq 60); do
  gpus=$(kubectl get node minikube -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  [ "${gpus:-0}" -ge 1 ] && break
  sleep 2
done
[ "${gpus:-0}" -ge 1 ] || { echo "No nvidia.com/gpu on the node after 2 min — check 'kubectl -n kube-system get pods'." >&2; exit 1; }
echo "GPUs allocatable: ${gpus}"

# The VLM's model cache is a hostPath — on the Docker driver that path lives
# inside the minikube node container, not on this host.
minikube ssh -- sudo mkdir -p /opt/edge-lab/hf-cache

# The ingest image is multi-GB (PyTorch/CUDA base). Long pulls from inside
# minikube's own Docker daemon were seen to stall on this host, while the
# host daemon pulls reliably — so the base image is pulled on the host once
# and loaded into minikube, then the (small) app layers build inside it.
BASE=$(grep -m1 -oP '^FROM\s+\K\S+' edge/ingest/Dockerfile)
if ! minikube ssh -- docker image inspect "${BASE}" >/dev/null 2>&1; then
  echo "Base image ${BASE} not in minikube yet: pulling on the host, then loading (one-off, several GB)..."
  docker pull "${BASE}"
  minikube image load "${BASE}"
fi
echo "Building edge-ingest:local inside minikube..."
eval "$(minikube docker-env)"
docker build -q -t edge-ingest:local edge/ingest >/dev/null
eval "$(minikube docker-env --unset)"

echo
echo "Edge cluster ready: node IP $(minikube ip), $(kubectl get node minikube -o jsonpath='{.status.nodeInfo.kubeletVersion}')."
echo "Next: ./lab.sh edge-apps up"
