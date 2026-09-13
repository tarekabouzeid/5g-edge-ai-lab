#!/usr/bin/env bash
# Phase 4: bootstrap a single-node K3s cluster on this host.
#
# K3s ships its own bundled containerd rather than using the OS one, which is
# why the GPU Operator install (install-gpu-operator.sh in this directory)
# needs to point at K3s's containerd config/socket explicitly instead of the
# defaults. Run this before that script.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a; source .env; set +a
fi

if [ -n "${K3S_VERSION:-}" ]; then
  echo "Installing K3s ${K3S_VERSION} (pinned, single node, this host as both server and agent)..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - \
    --write-kubeconfig-mode 644
else
  echo "Installing K3s from the 'stable' channel (always latest; single node)..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s - \
    --write-kubeconfig-mode 644
fi

echo
echo "Waiting for the node to become Ready..."
sudo k3s kubectl wait --for=condition=Ready node --all --timeout=120s

echo
echo "Node status:"
sudo k3s kubectl get nodes -o wide

echo
echo "Merging K3s's kubeconfig into ~/.kube/config as context 'k3s', so every"
echo "other script in this repo (and edge/kind's KIND path) can share one"
echo "ambient kubectl config instead of juggling KUBECONFIG per-backend..."
mkdir -p "${HOME}/.kube"
touch "${HOME}/.kube/config"
sudo sed -e 's/\bdefault\b/k3s/g' /etc/rancher/k3s/k3s.yaml | tee /tmp/k3s-renamed.yaml >/dev/null
sudo chown "$(id -u):$(id -g)" /tmp/k3s-renamed.yaml
KUBECONFIG="${HOME}/.kube/config:/tmp/k3s-renamed.yaml" kubectl config view --flatten > /tmp/kubeconfig-merged.yaml
mv /tmp/kubeconfig-merged.yaml "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
rm -f /tmp/k3s-renamed.yaml
KUBECONFIG="${HOME}/.kube/config" kubectl config use-context k3s >/dev/null

echo
echo "K3s is up and is now kubectl's current context (~/.kube/config)."
echo "Next: ./edge/install-gpu-operator.sh"
