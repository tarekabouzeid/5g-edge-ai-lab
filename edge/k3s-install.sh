#!/usr/bin/env bash
# Phase 4: bootstrap a single-node K3s cluster on this host.
#
# K3s ships its own bundled containerd rather than using the OS one, which is
# why the GPU Operator install (install-gpu-operator.sh in this directory)
# needs to point at K3s's containerd config/socket explicitly instead of the
# defaults. Run this before that script.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.30}"

echo "Installing K3s ${K3S_VERSION} (single node, this host as both server and agent)..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}+k3s1" sh -s - \
  --write-kubeconfig-mode 644

echo
echo "Waiting for the node to become Ready..."
sudo k3s kubectl wait --for=condition=Ready node --all --timeout=120s

echo
echo "Node status:"
sudo k3s kubectl get nodes -o wide

echo
echo "K3s is up. To use kubectl without sudo, either:"
echo "  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
echo "or copy that file to ~/.kube/config (mind the file permissions - it's a"
echo "cluster-admin credential, keep it out of git per this repo's .gitignore)."
echo
echo "Next: ./edge/install-gpu-operator.sh"
