"""
Phase 5 ingestion service: pulls an RTSP stream, runs a lightweight GPU
object-detection model (YOLOv8n) on each sampled frame, and periodically
forwards a frame to the Phase 6 VLM service's OpenAI-compatible API for a
caption/description.

This is the "GStreamer/OpenCV fallback" from PROJECT_PLAN.md Section 4,
chosen over NVIDIA DeepStream by default: DeepStream's install is tightly
version-pinned to a specific driver/CUDA/TensorRT combination that could not
be verified against the real host from this build session (see
docs/phase-notes/phase-0.md). This fallback needs only a CUDA-enabled
PyTorch build and gives real GPU inference load without that fragility. If
DeepStream is later confirmed to work on the real host, swap this
Deployment's image for one running the DeepStream pipeline; the Kubernetes
Service/manifest boundary (RTSP in, detections + VLM calls out) stays the
same either way.
"""
import base64
import logging
import os
import threading
import time

import cv2
import requests
from fastapi import FastAPI
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response
from ultralytics import YOLO

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ingest")

RTSP_URL = os.environ.get("RTSP_URL", "rtsp://mediamtx:8554/stream")
VLM_URL = os.environ.get("VLM_URL", "http://vlm:8000/v1/chat/completions")
VLM_MODEL = os.environ.get("VLM_MODEL", "Qwen/Qwen2-VL-7B-Instruct")
DETECT_EVERY_N_FRAMES = int(os.environ.get("DETECT_EVERY_N_FRAMES", "5"))
VLM_SAMPLE_EVERY_N_FRAMES = int(os.environ.get("VLM_SAMPLE_EVERY_N_FRAMES", "150"))
YOLO_WEIGHTS = os.environ.get("YOLO_WEIGHTS", "yolov8n.pt")

frames_ingested = Counter("frames_ingested_total", "Frames read from the RTSP source")
detections_total = Counter("detections_total", "Objects detected across all processed frames")
detect_latency = Histogram("detect_latency_seconds", "YOLO inference latency per frame")
vlm_calls_total = Counter("vlm_calls_total", "Frames sent to the VLM service")
vlm_latency = Histogram("vlm_latency_seconds", "VLM API round-trip latency")
vlm_errors_total = Counter("vlm_errors_total", "Failed VLM API calls")

app = FastAPI()
_state = {"last_caption": None, "last_detection_count": 0, "connected": False}


def _call_vlm(frame) -> str | None:
    ok, buf = cv2.imencode(".jpg", frame)
    if not ok:
        return None
    b64 = base64.b64encode(buf.tobytes()).decode("ascii")
    payload = {
        "model": VLM_MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Describe what is happening in this frame in one sentence."},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
                ],
            }
        ],
        "max_tokens": 128,
    }
    start = time.time()
    try:
        resp = requests.post(VLM_URL, json=payload, timeout=30)
        resp.raise_for_status()
        vlm_latency.observe(time.time() - start)
        vlm_calls_total.inc()
        return resp.json()["choices"][0]["message"]["content"]
    except Exception:
        vlm_errors_total.inc()
        log.exception("VLM call failed")
        return None


def _ingest_loop():
    model = YOLO(YOLO_WEIGHTS)
    frame_idx = 0
    while True:
        cap = cv2.VideoCapture(RTSP_URL)
        if not cap.isOpened():
            _state["connected"] = False
            log.warning("Could not open RTSP source %s, retrying in 5s", RTSP_URL)
            time.sleep(5)
            continue
        _state["connected"] = True
        log.info("Connected to %s", RTSP_URL)
        while True:
            ok, frame = cap.read()
            if not ok:
                log.warning("RTSP read failed, reconnecting")
                break
            frames_ingested.inc()
            frame_idx += 1

            if frame_idx % DETECT_EVERY_N_FRAMES == 0:
                start = time.time()
                results = model(frame, verbose=False)
                detect_latency.observe(time.time() - start)
                n = sum(len(r.boxes) for r in results)
                detections_total.inc(n)
                _state["last_detection_count"] = n

            if frame_idx % VLM_SAMPLE_EVERY_N_FRAMES == 0:
                caption = _call_vlm(frame)
                if caption:
                    _state["last_caption"] = caption
                    log.info("VLM caption: %s", caption)
        cap.release()
        _state["connected"] = False


@app.on_event("startup")
def start_background_loop():
    threading.Thread(target=_ingest_loop, daemon=True).start()


@app.get("/healthz")
def healthz():
    return {"connected": _state["connected"]}


@app.get("/status")
def status():
    return _state


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
