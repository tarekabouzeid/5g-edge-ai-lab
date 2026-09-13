#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-edge-ai-lab}"
kind delete cluster --name "${KIND_CLUSTER_NAME}"
