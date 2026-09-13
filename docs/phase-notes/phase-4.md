# Phase 4 — Edge K3s Cluster + GPU

## Status: Scaffolded, not yet run (see phase-0.md for why)

## What was built

- `edge/k3s-install.sh`: single-node K3s bootstrap via the official
  `get.k3s.io` installer.
- `edge/install-gpu-operator.sh`: installs the NVIDIA GPU Operator via its
  official Helm chart, with the `toolkit.env` overrides K3s specifically
  needs — K3s bundles its own containerd rather than using the OS one, so
  the toolkit has to be told K3s's containerd config path
  (`/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl`) and socket
  (`/run/k3s/containerd/containerd.sock`) instead of the defaults.
- `edge/gpu-operator/test-gpu-pod.yaml`: the Phase 4 DoD pod (`nvidia-smi`
  inside the cluster).

## How to run this for real (on the actual host, with the GPU driver already
verified working per Phase 0)

```bash
./edge/k3s-install.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm version   # install Helm first if missing: https://helm.sh/docs/intro/install/
./edge/install-gpu-operator.sh
```

## DoD (copy real output here once run on the target host)

- [ ] `kubectl describe node` shows `nvidia.com/gpu` in allocatable resources
- [ ] `gpu-smi-test` pod's log shows real `nvidia-smi` output

## Known risks to watch for on first real run

- The GPU Operator's driver container build/DKMS step is the most likely
  first failure point on an unusual kernel — if it fails, check
  `kubectl -n gpu-operator logs -l app=nvidia-driver-daemonset` for the
  actual DKMS/kernel-header error before assuming the Operator itself is
  broken.
- If the host already has the NVIDIA driver installed and working
  (confirmed via the Phase 0 `nvidia-smi` check), consider re-running the
  install with `--set driver.enabled=false` to have the Operator use the
  host driver instead of building its own — simpler and faster, at the cost
  of the Operator not managing driver upgrades.
- `CONTAINERD_CONFIG` path ends in `.toml.tmpl`, not `.toml` — this is a K3s
  peculiarity (K3s regenerates `config.toml` from the `.tmpl` at every
  start) and is easy to get wrong when copying non-K3s GPU Operator
  instructions.
