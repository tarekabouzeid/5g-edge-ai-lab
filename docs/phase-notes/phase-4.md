# Phase 4 — Edge K3s Cluster + GPU

## Status: Run for real on a WSL2 host with an NVIDIA GPU, 2026-09-20 — DoD met

## Current path: minikube with GPU passthrough (2026-09-22 onwards)

After the K3s + GPU Operator route kept breaking on WSL2 (three separate
issues, all documented under "Known risks" below), the edge cluster moved to
**minikube on the Docker driver with `--gpus=nvidia.com`** — the stack the
whole lab is now verified on end to end. `./lab.sh minikube up`
(`edge/minikube-up.sh`) starts it, waits for `nvidia.com/gpu` to be
allocatable (minikube's NVIDIA device plugin addon), creates the VLM model
cache inside the node, and builds the ingest image. No sudo. The K3s
material below still applies to bare-metal Linux (`./lab.sh all up --k3s`).

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

## DoD (real output, WSL2 host, 2026-09-20)

- [x] `kubectl describe node` shows `nvidia.com/gpu` in allocatable resources:
  ```
    nvidia.com/gpu:     1
    pods:               110
  ```
- [x] `gpu-smi-test` pod's log shows real `nvidia-smi` output (this run's
  card happened to be an RTX 5070 Ti — the DoD itself only requires that
  *some* real GPU shows up here, not that specific model):
  ```
  NVIDIA-SMI 615.71.08   ... NVIDIA GeForce RTX 5070 Ti   ...   16303MiB
  ```

Both confirmed via `./edge/gpu-operator/test-gpu-pod.yaml` after the WSL2
workarounds below were applied. `nvidia-dcgm-exporter` also came up healthy
(HTTP server listening on `:9400`, GPU metrics registry built — the "not
collecting CPU metrics" log lines are benign, DCGM's CPU module isn't loaded
and isn't needed here).

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
  of the Operator not managing driver upgrades. **On WSL2 this isn't
  optional** — see below.
- `CONTAINERD_CONFIG` path ends in `.toml.tmpl`, not `.toml` — this is a K3s
  peculiarity (K3s regenerates `config.toml` from the `.tmpl` at every
  start) and is easy to get wrong when copying non-K3s GPU Operator
  instructions.

### WSL2-specific (hit for real on this host, not hypothetical)

- **The GPU Operator's bundled Node Feature Discovery can never detect the
  GPU on WSL2**, so it sits forever logging `"No GPU node found, watching
  for new nodes to join the cluster."` even though `nvidia-smi` and `docker
  run --gpus all` both work fine. Cause: WSL2 exposes the GPU to the guest
  kernel via Microsoft's paravirtualized `/dev/dxg`, so NFD's PCI scan sees
  vendor `1414` (Microsoft), never `10de` (NVIDIA) — the vendor ID the
  Operator's default GPU-node detection rule looks for. Manually labeling
  the node (`kubectl label node ... nvidia.com/gpu.present=true`) does not
  stick — NFD's worker reconciles it back to `false` every ~60–90s. Fix:
  reinstall/upgrade with **both** `--set nfd.enabled=false` (stops NFD from
  fighting the label) **and** `--set driver.enabled=false` (the host driver
  already works; the Operator's own DKMS driver build is irrelevant on
  WSL2 anyway), then apply the label yourself:
  ```bash
  helm upgrade --install gpu-operator nvidia/gpu-operator \
    -n gpu-operator --create-namespace \
    --set driver.enabled=false \
    --set nfd.enabled=false \
    --set 'toolkit.env[0].name=CONTAINERD_CONFIG' \
    --set 'toolkit.env[0].value=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl' \
    --set 'toolkit.env[1].name=CONTAINERD_SOCKET' \
    --set 'toolkit.env[1].value=/run/k3s/containerd/containerd.sock' \
    --set 'toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS' \
    --set 'toolkit.env[2].value=nvidia' \
    --set 'toolkit.env[3].name=CONTAINERD_SET_AS_DEFAULT' \
    --set-string 'toolkit.env[3].value=true'
  kubectl label node <node> nvidia.com/gpu.present=true feature.node.kubernetes.io/pci-10de.present=true --overwrite
  ```
  (zsh users: the `[0]`/`[1]`/... need quoting, e.g. `--set 'toolkit.env[0].name=...'`, or zsh glob-expands the brackets and errors with `no matches found`.)

- **The toolkit's `driver-validation` init container fails with `path "/"
  is mounted on "/" but it is not a shared or slave mount`.** WSL2's root
  filesystem defaults to `private` mount propagation; containerd's
  bidirectional host-validation mounts require `shared`/`slave`. Fix:
  ```bash
  sudo mount --make-rshared /
  ```
  Check current state first with `findmnt -o TARGET,PROPAGATION /`. **This
  does not persist across a WSL restart** (`wsl --shutdown` or a Windows
  reboot resets it) — if GPU Operator pods that previously worked start
  failing with this same error again, this is the first thing to check and
  re-run, before assuming something else broke. Not yet automated via
  `/etc/wsl.conf`'s `[boot] command=` — worth doing if this repo starts
  seeing repeat WSL restarts during development.

- After applying both fixes, pods stuck in `Init:CreateContainerError` from
  before the fix don't self-heal instantly — delete them to force an
  immediate retry instead of waiting out kubelet's backoff:
  ```bash
  kubectl -n gpu-operator delete pod -l app=nvidia-container-toolkit-daemonset
  kubectl -n gpu-operator delete pod -l app=nvidia-operator-validator
  ```
