#!/usr/bin/env bash
# Phase 4: install the NVIDIA GPU Operator on the K3s cluster from
# edge/k3s-install.sh, wired to K3s's bundled containerd (not the OS one).
#
# Prerequisites (Phase 0, verified on THIS host, not the build container —
# see docs/phase-notes/phase-0.md):
#   - NVIDIA driver installed, `nvidia-smi` works on the host
#   - `docker run --rm --gpus all ... nvidia-smi` works
#   - K3s already installed and Ready (edge/k3s-install.sh)
#
# The GPU Operator manages the driver/toolkit/device-plugin/DCGM containers
# itself inside the cluster, so `driver.enabled` is left at its default
# (true) here; if the host driver is already installed and you'd rather the
# Operator not also try to manage it, add `--set driver.enabled=false`.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi
# Uses kubectl's ambient current-context (~/.kube/config) — edge/k3s-install.sh
# already merged K3s's credentials in as context 'k3s' and selected it.
kubectl config use-context k3s >/dev/null 2>&1 || true

echo "Adding the NVIDIA helm repo..."
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update

# GPU_OPERATOR_VERSION in .env pins a chart version for reproducibility
# (v26.7.0 was latest as of 2026-09-13); leave it unset to always install
# whatever `helm repo update` just fetched as the newest chart.
VERSION_ARGS=()
if [ -n "${GPU_OPERATOR_VERSION:-}" ]; then
  VERSION_ARGS=(--version "${GPU_OPERATOR_VERSION#v}")
fi

echo
echo "Installing gpu-operator into namespace gpu-operator, pointed at K3s's"
echo "bundled containerd (not the host's system containerd)..."
helm upgrade --install --wait --timeout 15m \
  gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace \
  "${VERSION_ARGS[@]}" \
  --set toolkit.env[0].name=CONTAINERD_CONFIG \
  --set toolkit.env[0].value=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl \
  --set toolkit.env[1].name=CONTAINERD_SOCKET \
  --set toolkit.env[1].value=/run/k3s/containerd/containerd.sock \
  --set toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS \
  --set toolkit.env[2].value=nvidia \
  --set toolkit.env[3].name=CONTAINERD_SET_AS_DEFAULT \
  --set-string toolkit.env[3].value=true

echo
echo "Waiting for GPU Operator pods to become Ready (this includes building"
echo "the driver container, which can take several minutes on first install)..."
kubectl -n gpu-operator wait --for=condition=Ready pod --all --timeout=15m

echo
echo "=== Phase 4 DoD checks ==="
echo "--- kubectl describe node | grep nvidia.com/gpu ---"
kubectl describe node | grep -A2 "nvidia.com/gpu" || \
  echo "FAIL: nvidia.com/gpu not found in node allocatable resources yet."

echo
echo "--- test pod requesting the GPU ---"
kubectl apply -f "$(dirname "$0")/gpu-operator/test-gpu-pod.yaml"
kubectl wait --for=condition=Ready pod/gpu-smi-test --timeout=120s
kubectl logs gpu-smi-test
kubectl delete -f "$(dirname "$0")/gpu-operator/test-gpu-pod.yaml"
