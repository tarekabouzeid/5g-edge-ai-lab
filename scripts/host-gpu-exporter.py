#!/usr/bin/env python3
"""
Tiny Prometheus exporter for GPU stats read from nvidia-smi on the host.

Stand-in for NVIDIA's DCGM exporter, which doesn't run under WSL2. Emits the
same metric names the Grafana dashboard's GPU panels query
(DCGM_FI_DEV_GPU_UTIL / _FB_USED / _GPU_TEMP), so nothing else changes.
Prometheus inside minikube scrapes it via the host's minikube-bridge IP
(192.168.49.1:9400).

Normally run as the `gpu-exporter` service in portal/docker-compose.yml
(started by ./lab.sh portal up); standalone: ./scripts/host-gpu-exporter.py [port]
"""
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

QUERY = "index,name,utilization.gpu,memory.used,temperature.gpu,power.draw"
METRICS = [
    ("DCGM_FI_DEV_GPU_UTIL", "GPU utilization (%)", 2),
    ("DCGM_FI_DEV_FB_USED", "Framebuffer memory used (MiB)", 3),
    ("DCGM_FI_DEV_GPU_TEMP", "GPU temperature (C)", 4),
    ("DCGM_FI_DEV_POWER_USAGE", "Power draw (W)", 5),
]


def scrape() -> str:
    out = subprocess.run(
        ["nvidia-smi", f"--query-gpu={QUERY}", "--format=csv,noheader,nounits"],
        capture_output=True, text=True, timeout=5, check=True,
    ).stdout
    rows = [[f.strip() for f in line.split(",")] for line in out.strip().splitlines()]
    lines = []
    for name, help_text, col in METRICS:
        lines += [f"# HELP {name} {help_text}", f"# TYPE {name} gauge"]
        for r in rows:
            try:
                value = float(r[col])
            except ValueError:
                continue
            lines.append(f'{name}{{gpu="{r[0]}",modelName="{r[1]}"}} {value}')
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        try:
            body, code = scrape().encode(), 200
        except Exception as e:
            body, code = f"# nvidia-smi failed: {e}\n".encode(), 500
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9400
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
