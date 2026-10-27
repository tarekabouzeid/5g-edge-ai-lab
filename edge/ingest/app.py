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
import jwt
import requests
from fastapi import FastAPI, HTTPException, Request
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import FileResponse, JSONResponse, Response, StreamingResponse
from ultralytics import YOLO

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ingest")

RTSP_BASE = os.environ.get("RTSP_BASE", "rtsp://edge-gateway:8554")
# Security (docs/security.md). This pod is an OAuth 2.0 client of edge-authz
# (client credentials, secret from the edge-auth Secret): its token lets it
# read ue/* streams and use the gateway API. Its own API accepts only JWTs
# from edge-authz with the right scope; tokens bound to a client certificate
# (phones, the portal) must arrive with that certificate (Envoy's XFCC).
AUTHZ_URL = os.environ.get("AUTHZ_URL", "http://edge-authz:8080")
CLIENT_ID = os.environ.get("CLIENT_ID", "edge-ingest")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET", "")
TOKEN_ISSUER = os.environ.get("TOKEN_ISSUER", "https://edge.lab/authz")
TOKEN_AUDIENCE = os.environ.get("TOKEN_AUDIENCE", "edge-eas")
VLM_API_KEY = os.environ.get("VLM_API_KEY", "")
# No token needed: liveness/readiness and the portal's round-trip probe.
# "/" is the static page shell; its data calls need a token.
PUBLIC_PATHS = {"/healthz", "/"}
ROUTE_SCOPES = {"/api/ask": "ai.ask", "/metrics": "metrics.read"}  # everything else: ingest.read
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
_active_path = None  # the ue/<EEC ID> stream being analysed (newest publisher)


class _ServiceToken:
    """This pod's own access token, refreshed a minute before it expires."""

    def __init__(self):
        self._lock = threading.Lock()
        self._token, self._exp = None, 0.0

    def get(self):
        with self._lock:
            if self._token is None or time.time() > self._exp - 60:
                r = requests.post(f"{AUTHZ_URL}/token", auth=(CLIENT_ID, CLIENT_SECRET),
                                  data={"grant_type": "client_credentials"}, timeout=5)
                r.raise_for_status()
                body = r.json()
                self._token, self._exp = body["access_token"], time.time() + body["expires_in"]
            return self._token


_service_token = _ServiceToken()
_jwks = jwt.PyJWKClient(f"{AUTHZ_URL}/jwks.json", cache_keys=True)


@asynccontextmanager
async def lifespan(app: FastAPI):
    threading.Thread(target=_ingest_loop, daemon=True).start()
    threading.Thread(target=_gateway_poll_loop, daemon=True).start()
    yield


app = FastAPI(lifespan=lifespan)


def _bearer(request: Request) -> str:
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    # The browser demo page: <img> tags can't send headers.
    return request.query_params.get("token", "")


def _cert_hash_b64(request: Request):
    # Envoy (XFCC SanitizeSet) puts the verified client cert's SHA-256 here.
    m = next((p for p in request.headers.get("x-forwarded-client-cert", "").split(";") if p.startswith("Hash=")), None)
    return base64.urlsafe_b64encode(bytes.fromhex(m[5:])).rstrip(b"=").decode() if m else None


@app.middleware("http")
async def require_token(request: Request, call_next):
    path = request.url.path
    if path in PUBLIC_PATHS:
        return await call_next(request)
    token = _bearer(request)
    if not token:
        return JSONResponse({"detail": "access token required"}, status_code=401,
                            headers={"WWW-Authenticate": "Bearer"})
    try:
        key = _jwks.get_signing_key_from_jwt(token).key
        claims = jwt.decode(token, key, algorithms=["RS256"], audience=TOKEN_AUDIENCE, issuer=TOKEN_ISSUER)
    except jwt.PyJWKClientConnectionError:
        return JSONResponse({"detail": "authorization server unreachable"}, status_code=503)
    except jwt.PyJWTError:
        return JSONResponse({"detail": "invalid access token"}, status_code=401,
                            headers={"WWW-Authenticate": 'Bearer error="invalid_token"'})
    # RFC 8705: a certificate-bound token is only valid with that certificate.
    cnf = (claims.get("cnf") or {}).get("x5t#S256")
    if cnf and cnf != _cert_hash_b64(request):
        return JSONResponse({"detail": "token is bound to a different client certificate"}, status_code=401)
    needed = ROUTE_SCOPES.get(path, "ingest.read")
    if needed not in claims.get("scope", "").split():
        return JSONResponse({"detail": f"scope {needed} required"}, status_code=403,
                            headers={"WWW-Authenticate": f'Bearer error="insufficient_scope", scope="{needed}"'})
    return await call_next(request)


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
    # mediamtx's API reports each publisher's path (ue/<EEC ID>) and remote
    # address — the UE's un-NAT'd edge-DNN IP, carried through Envoy by the
    # PROXY protocol. The newest publisher is the one analysed.
    global _active_path
    while True:
        try:
            headers = {"Authorization": f"Bearer {_service_token.get()}"}
            items = requests.get(f"{GATEWAY_API_URL}/v3/rtspsessions/list", headers=headers, timeout=2).json().get("items", [])
            pubs = sorted((s for s in items if s.get("state") == "publish"), key=lambda s: s.get("created", ""))
            pub = pubs[-1] if pubs else None
            _active_path = pub.get("path") if pub else None
            _live["publisher"] = (
                {"ip": pub["remoteAddr"].rsplit(":", 1)[0], "path": pub.get("path"),
                 "ue": (pub.get("path") or "").removeprefix("ue/"), "publishers": len(pubs),
                 "bytes_received": pub.get("inboundBytes", pub.get("bytesReceived", 0))}
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
        headers = {"Authorization": f"Bearer {VLM_API_KEY}"} if VLM_API_KEY else {}  # static: llama-server
        resp = requests.post(VLM_URL, json=payload, headers=headers, timeout=30)
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
        path = _active_path
        if not path:
            _state["connected"] = False
            time.sleep(1)
            continue
        source = f"{RTSP_BASE}/{path}"
        try:
            # The token is the RTSP password; this URL is never logged.
            cap = cv2.VideoCapture(source.replace("rtsp://", f"rtsp://{CLIENT_ID}:{_service_token.get()}@", 1))
        except requests.RequestException as e:
            log.warning("No access token from edge-authz (%s), retrying in 5s", e)
            time.sleep(5)
            continue
        if not cap.isOpened():
            _state["connected"] = False
            log.warning("Could not open RTSP source %s, retrying in 5s", source)
            time.sleep(5)
            continue
        _state["connected"] = True
        _state["source"] = path
        log.info("Connected to %s", source)
        while True:
            if _active_path != path:
                log.info("Newer publisher on %s, switching", _active_path)
                break
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
