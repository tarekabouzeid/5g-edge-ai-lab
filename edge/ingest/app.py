"""
Phase 5 ingestion service: pulls an RTSP stream, runs a lightweight
object-detection model (YOLOv8n; CPU in the single-GPU layout) on each
sampled frame, and periodically forwards a frame to the Phase 6 VLM
service's OpenAI-compatible API for a caption/description. Also serves the
live demo page at / (annotated MJPEG video, caption feed, pipeline stats).

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
from collections import Counter as TallyCounter
from collections import deque
from contextlib import asynccontextmanager

import cv2
import requests
from fastapi import FastAPI, HTTPException
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import FileResponse, Response, StreamingResponse
from ultralytics import YOLO

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ingest")

RTSP_URL = os.environ.get("RTSP_URL", "rtsp://mediamtx:8554/stream")
VLM_URL = os.environ.get("VLM_URL", "http://vlm:8000/v1/chat/completions")
VLM_MODEL = os.environ.get("VLM_MODEL", "google/gemma-4-E4B-it")
DETECT_EVERY_N_FRAMES = int(os.environ.get("DETECT_EVERY_N_FRAMES", "5"))
# Time-based, not frame-based: frame counts silently change the cadence with
# the source's fps (36 frames was ~3s at 12fps but 1.2s at 30fps).
VLM_INTERVAL_SECONDS = float(os.environ.get("VLM_INTERVAL_SECONDS", "4"))
CAPTION_PROMPT = "Describe what is happening in this frame in one sentence."
YOLO_WEIGHTS = os.environ.get("YOLO_WEIGHTS", "yolov8n.pt")
GATEWAY_API_URL = os.environ.get("GATEWAY_API_URL", "http://edge-gateway-api:9997")
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

frames_ingested = Counter("frames_ingested_total", "Frames read from the RTSP source")
detections_total = Counter("detections_total", "Objects detected across all processed frames")
detect_latency = Histogram("detect_latency_seconds", "YOLO inference latency per frame")
vlm_calls_total = Counter("vlm_calls_total", "Frames sent to the VLM service")
vlm_latency = Histogram("vlm_latency_seconds", "VLM API round-trip latency")
vlm_errors_total = Counter("vlm_errors_total", "Failed VLM API calls")

_state = {"last_caption": None, "last_detection_count": 0, "connected": False}
_live = {"ingest_fps": 0.0, "detect_ms": None, "labels": {}, "publisher": None, "boxes": [], "frame_size": None}
_captions = deque(maxlen=20)
_frame_lock = threading.Lock()
_latest_jpeg = None
_latest_raw = None
_vlm_busy = threading.Event()


@asynccontextmanager
async def lifespan(app: FastAPI):
    threading.Thread(target=_ingest_loop, daemon=True).start()
    threading.Thread(target=_gateway_poll_loop, daemon=True).start()
    yield


app = FastAPI(lifespan=lifespan)


def _vlm_worker(frame):
    try:
        start = time.time()
        caption = _call_vlm(frame)
        if caption:
            _state["last_caption"] = caption
            _captions.appendleft({"ts": time.time(), "latency_ms": round((time.time() - start) * 1000), "text": caption})
            log.info("VLM caption: %s", caption)
    finally:
        _vlm_busy.clear()


def _draw_boxes(frame, boxes, names):
    for (x1, y1, x2, y2), cls, conf in boxes:
        label = f"{names[cls]} {conf:.2f}"
        cv2.rectangle(frame, (x1, y1), (x2, y2), (80, 220, 120), 2)
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
        cv2.rectangle(frame, (x1, y1 - th - 6), (x1 + tw + 6, y1), (80, 220, 120), -1)
        cv2.putText(frame, label, (x1 + 3, y1 - 4), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (20, 20, 20), 1, cv2.LINE_AA)


def _gateway_poll_loop():
    # mediamtx's API reports the RTSP publisher's remote address — i.e. the
    # UE's un-NAT'd edge-DNN IP when the stream comes in over the 5G path.
    while True:
        try:
            items = requests.get(f"{GATEWAY_API_URL}/v3/rtspsessions/list", timeout=2).json().get("items", [])
            pub = next((s for s in items if s.get("state") == "publish"), None)
            _live["publisher"] = (
                {"ip": pub["remoteAddr"].rsplit(":", 1)[0], "bytes_received": pub.get("inboundBytes", pub.get("bytesReceived", 0))}
                if pub else None
            )
        except Exception:
            _live["publisher"] = None
        time.sleep(2)


def _call_vlm(frame, prompt=CAPTION_PROMPT, max_tokens=128) -> str | None:
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
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
                ],
            }
        ],
        "max_tokens": max_tokens,
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
    global _latest_jpeg, _latest_raw
    model = YOLO(YOLO_WEIGHTS)
    frame_idx = 0
    boxes = []
    fps_count, fps_t0 = 0, time.time()
    last_vlm = 0.0
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
            fps_count += 1
            now = time.time()
            if now - fps_t0 >= 1.0:
                _live["ingest_fps"] = round(fps_count / (now - fps_t0), 1)
                fps_count, fps_t0 = 0, now

            if frame_idx % DETECT_EVERY_N_FRAMES == 0:
                start = time.time()
                r = model(frame, verbose=False)[0]
                elapsed = time.time() - start
                detect_latency.observe(elapsed)
                _live["detect_ms"] = round(elapsed * 1000)
                boxes = [
                    (tuple(int(v) for v in xyxy), int(c), float(p))
                    for xyxy, c, p in zip(r.boxes.xyxy.tolist(), r.boxes.cls.tolist(), r.boxes.conf.tolist())
                ]
                n = len(boxes)
                detections_total.inc(n)
                _state["last_detection_count"] = n
                _live["labels"] = dict(TallyCounter(r.names[c] for _, c, _ in boxes))
                h, w = frame.shape[:2]
                _live["frame_size"] = [w, h]
                _live["boxes"] = [
                    [round(x1 / w, 4), round(y1 / h, 4), round(x2 / w, 4), round(y2 / h, 4), r.names[c], round(p, 2)]
                    for (x1, y1, x2, y2), c, p in boxes
                ]

            if now - last_vlm >= VLM_INTERVAL_SECONDS and not _vlm_busy.is_set():
                last_vlm = now
                _vlm_busy.set()
                threading.Thread(target=_vlm_worker, args=(frame.copy(),), daemon=True).start()

            shown = frame.copy()
            _draw_boxes(shown, boxes, model.names)
            ok, buf = cv2.imencode(".jpg", shown, [cv2.IMWRITE_JPEG_QUALITY, 75])
            if ok:
                with _frame_lock:
                    _latest_jpeg = buf.tobytes()
                    _latest_raw = frame
        cap.release()
        _state["connected"] = False
        _live["ingest_fps"] = 0.0
        _live["boxes"] = []
        boxes = []


@app.get("/healthz")
def healthz():
    return {"connected": _state["connected"]}


@app.get("/status")
def status():
    return _state


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC_DIR, "index.html"))


@app.get("/api/state")
def api_state():
    captions = list(_captions)
    return {
        **_state,
        **_live,
        "captions": captions,
        "vlm_avg_ms": round(sum(c["latency_ms"] for c in captions) / len(captions)) if captions else None,
        "vlm_busy": _vlm_busy.is_set(),
    }


@app.post("/api/ask")
def ask(body: dict):
    question = str(body.get("question", "")).strip()[:300]
    if not question:
        raise HTTPException(400, "question is required")
    with _frame_lock:
        frame = _latest_raw
    if frame is None:
        raise HTTPException(409, "no video yet")
    start = time.time()
    answer = _call_vlm(frame, f"{question}\nAnswer briefly, in one or two sentences.", max_tokens=96)
    if answer is None:
        raise HTTPException(502, "vision-language model unavailable")
    return {"answer": answer.strip(), "latency_ms": round((time.time() - start) * 1000), "ts": time.time()}


@app.get("/frame.jpg")
def frame_jpg():
    with _frame_lock:
        buf = _latest_jpeg
    if buf is None:
        raise HTTPException(404, "no video yet")
    return Response(buf, media_type="image/jpeg")


def _mjpeg():
    last = None
    while True:
        with _frame_lock:
            buf = _latest_jpeg
        if buf is not None and buf is not last:
            last = buf
            yield b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(buf)).encode() + b"\r\n\r\n" + buf + b"\r\n"
        time.sleep(0.03)


@app.get("/stream.mjpg")
def stream():
    return StreamingResponse(_mjpeg(), media_type="multipart/x-mixed-replace; boundary=frame")
