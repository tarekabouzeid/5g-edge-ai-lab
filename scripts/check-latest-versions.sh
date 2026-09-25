#!/usr/bin/env bash
# Queries each component's registry for its newest tag/release and diffs it
# against what's pinned in .env.example and the K8s manifests, so version
# drift is a one-command check instead of manual registry browsing.
#
# Network-only, read-only — safe to run anytime, including in CI.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

dockerhub_latest() {
  # $1 = "namespace/repo", $2 = grep pattern for tag names to consider
  curl -s "https://hub.docker.com/v2/repositories/$1/tags?page_size=100&ordering=last_updated" \
    | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
pat = re.compile(r'''$2''')
for r in d.get('results', []):
    if pat.fullmatch(r['name']):
        print(r['name']); break
"
}

pypi_latest() {
  curl -s "https://pypi.org/pypi/$1/json" | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['version'])"
}

github_latest_tag() {
  # Some sandboxes (including the one this repo was first scaffolded in)
  # block github.com/api.github.com outright, unrelated to this script —
  # degrade to a clear note instead of a bare parse error in that case.
  curl -s "https://api.github.com/repos/$1/releases/latest" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tag_name') or d.get('message', 'unavailable'))
except Exception:
    print('unavailable (network-restricted?)')
"
}

echo "=== Container images ==="
printf '%-32s %-16s %s\n' "component" "pinned" "latest seen"
printf '%-32s %-16s %s\n' "gradiant/open5gs" "$(grep -oP 'OPEN5GS_IMAGE_TAG=\K.*' .env.example)" "$(dockerhub_latest gradiant/open5gs '\d+\.\d+\.\d+')"
printf '%-32s %-16s %s\n' "gradiant/ueransim" "$(grep -oP 'UERANSIM_IMAGE_TAG=\K.*' .env.example)" "$(dockerhub_latest gradiant/ueransim '\d+\.\d+\.\d+')"
printf '%-32s %-16s %s\n' "gradiant/open5gs-dbctl" "$(grep -oP 'DBCTL_IMAGE_TAG=\K.*' .env.example)" "$(dockerhub_latest gradiant/open5gs-dbctl '\d+\.\d+\.\d+')"
printf '%-32s %-16s %s\n' "mongo" "$(grep -oP 'MONGO_IMAGE_TAG=\K.*' .env.example)" "$(dockerhub_latest library/mongo '\d+\.\d+\.\d+')"
printf '%-32s %-16s %s\n' "ghcr.io/ggml-org/llama.cpp" "$(grep -oP 'LLAMACPP_IMAGE_TAG=\K.*' .env.example)" "server-cuda-$(github_latest_tag ggml-org/llama.cpp)"
printf '%-32s %-16s %s\n' "python (portal base image)" "$(grep -oP '^FROM python:\K.*' portal/Dockerfile)" "$(dockerhub_latest library/python '3\.12\.\d+-slim')"
printf '%-32s %-16s %s\n' "bluenviron/mediamtx" "$(grep -oP 'MEDIAMTX_IMAGE_TAG=\K.*' .env.example)" "$(dockerhub_latest bluenviron/mediamtx '\d+\.\d+\.\d+')"
printf '%-32s %-16s %s\n' "prom/prometheus" "$(grep -oP 'PROMETHEUS_IMAGE_TAG=\K.*' .env.example)" "$(dockerhub_latest prom/prometheus 'v\d+\.\d+\.\d+')"
printf '%-32s %-16s %s\n' "grafana/grafana" "$(grep -oP 'GRAFANA_IMAGE_TAG=\K.*' .env.example)" "$(dockerhub_latest grafana/grafana '\d+\.\d+\.\d+')"


echo
echo "=== Python packages (edge/ingest, portal) ==="
for pkg in fastapi uvicorn opencv-python ultralytics requests prometheus-client httpx docker python-multipart; do
  pinned=$(grep -hoP "^${pkg}(\[[a-z]+\])?==\K.*" edge/ingest/requirements.txt portal/requirements.txt 2>/dev/null | head -1)
  printf '%-32s %-16s %s\n' "$pkg" "${pinned:-n/a}" "$(pypi_latest "$pkg")"
done

echo
echo "Anything in 'latest seen' newer than 'pinned' is worth a deliberate bump"
echo "(update .env.example / the manifest / requirements.txt together, then"
echo "re-run this script to confirm)."
