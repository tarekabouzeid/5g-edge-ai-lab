# Build on the real host (needs the NVIDIA Container Toolkit to test with
# --gpus all; see docs/phase-notes/phase-0.md for why that can't happen from
# the build session this repo was scaffolded from):
#   docker build -t edge-ingest:local edge/ingest
#   docker run --rm --gpus all edge-ingest:local python -c "import torch; print(torch.cuda.is_available())"
# Then import into K3s's containerd (no external registry needed for a
# single-node lab):
#   docker save edge-ingest:local | sudo k3s ctr images import -
# and set edge/manifests/ingest-deployment.yaml's image to edge-ingest:local
# with imagePullPolicy: Never.
FROM pytorch/pytorch:2.14.0-cuda13.0-cudnn9-runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 libglib2.0-0 ffmpeg && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
# --break-system-packages: this pytorch/pytorch base image's Python is
# marked externally-managed (PEP 668) as of the 2.14.0 image; there's no
# system package manager use to protect from inside a single-purpose
# container, so overriding it is the correct call here, not a workaround.
RUN pip install --no-cache-dir --break-system-packages -r requirements.txt

COPY app.py .

# Pre-fetch the tiny YOLOv8n weights at build time so the first request
# doesn't stall on a download.
RUN python -c "from ultralytics import YOLO; YOLO('yolov8n.pt')"

EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
