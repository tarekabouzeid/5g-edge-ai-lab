"""
Lab portal: mission-control UI + controller for the 5G edge-AI lab.

Runs on the host network (see portal/docker-compose.yml) with the Docker
socket, because driving the simulated phone means `docker exec` into the
UERANSIM UE container (nr-cli, routes, ffmpeg) and reading the Open5GS
containers' logs — neither of which the in-cluster pods can or should do.
Binds to 127.0.0.1 only: anything that can reach it can control containers.

Everything shown is read from the real system: UE state from nr-cli, the
attach timeline from the gNB/AMF/SMF/UPF/UE logs, counters from the
Open5GS /metrics endpoints and the UPF's TUN interfaces, RTT measured with
curl from inside the UE over each PDU session. The one emulated piece is the
"central cloud" WAN delay, added by a TCP relay in this process (the WSL2
kernel has no sch_netem) — the UI labels it as emulated.
"""
import asyncio
import io
import json
import logging
import os
import re
import tarfile
import threading
import time
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime

import docker
import httpx
from fastapi import FastAPI, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("portal")
logging.getLogger("httpx").setLevel(logging.WARNING)

UE = os.environ.get("UE_CONTAINER", "ueransim-ue")
GNB = os.environ.get("GNB_CONTAINER", "ueransim-gnb")
UPF = os.environ.get("UPF_CONTAINER", "open5gs-upf")
UE_IMSI = os.environ.get("UE_IMSI", "imsi-999700000000001")
EDGE_NODE_IP = os.environ.get("EDGE_NODE_IP", "192.168.49.2")
RTSP_NODEPORT = int(os.environ.get("RTSP_NODEPORT", "30554"))
INGEST_NODEPORT = int(os.environ.get("INGEST_NODEPORT", "30080"))
CENTRAL_BIND_IP = os.environ.get("CENTRAL_BIND_IP", "10.10.0.1")
CENTRAL_RTSP_PORT = int(os.environ.get("CENTRAL_RTSP_PORT", "30555"))
CENTRAL_PROBE_PORT = int(os.environ.get("CENTRAL_PROBE_PORT", "30556"))
EDGE_PREFIX = os.environ.get("EDGE_UE_PREFIX", "10.47.")
INTERNET_PREFIX = os.environ.get("INTERNET_UE_PREFIX", "10.45.")
UPF_TUN = {"internet": os.environ.get("UPF_TUN_INTERNET", "ogstun"), "edge": os.environ.get("UPF_TUN_EDGE", "ogstun2")}
CORE_METRICS = {
    "amf": os.environ.get("AMF_METRICS", "http://10.10.0.5:9090/metrics"),
    "smf": os.environ.get("SMF_METRICS", "http://10.10.0.4:9090/metrics"),
    "upf": os.environ.get("UPF_METRICS", "http://10.10.0.7:9090/metrics"),
}
MEDIA_DIR = os.environ.get("MEDIA_DIR", "/media")
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
INGEST_URL = f"http://{EDGE_NODE_IP}:{INGEST_NODEPORT}"
VIDEO_EXTS = (".mp4", ".mov", ".mkv", ".webm", ".avi")
TEST_PATTERN = "test-pattern"
MAX_UPLOAD_BYTES = 300 * 1024 * 1024
FFMPEG_MATCH = "[f]fmpeg .*rtsp://"

dk = docker.from_env()

# Operator intent. Reconciled against reality by _reconcile_loop.
desired = {"camera": False, "video": "traffic.mp4", "mode": "edge", "wan_delay_ms": 25}
snapshot: dict = {}
op = {"name": None, "started": None, "error": None}
op_lock = threading.Lock()
probe = {"edge_ms": None, "central_ms": None, "edge_fail": 0, "last": None}
relay_clients: dict = {}
upf_prev = {"t": None, "bytes": {}}
restart_backoff = {"n": 0, "until": 0}

STATE_FILE = os.path.join(MEDIA_DIR, ".portal-state.json")


def save_desired():
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(desired, f)
    except OSError:
        pass


def load_desired():
    try:
        with open(STATE_FILE) as f:
            desired.update({k: v for k, v in json.load(f).items() if k in desired})
    except (OSError, ValueError):
        pass


EVENTS: deque = deque(maxlen=400)
_event_lock = threading.Lock()
_event_id = 0
_recent_titles: dict = {}


# ----------------------------------------------------------------- events

def emit(src, title, detail="", kind="info", ts=None):
    global _event_id
    ts = ts or time.time()
    key = (src, title)
    with _event_lock:
        if key in _recent_titles and abs(ts - _recent_titles[key]) < 1.5:
            return
        _recent_titles[key] = ts
        _event_id += 1
        EVENTS.append({"id": _event_id, "ts": ts, "src": src, "title": title, "detail": detail, "kind": kind})


ANSI = re.compile(r"\x1b\[[0-9;]*m")


def _parse_ue(m):
    if "PLMN-SEARCH" in m:
        return "UE", "Scanning for a 5G network", "", "info"
    if "Cell selection failure" in m:
        return "UE", "No usable cell yet — retrying", "cell not broadcasting system info", "warn"
    if r := re.search(r"Selected cell plmn\[([\d/]+)\] tac\[(\d+)\]", m):
        return "UE", f"Found cell · PLMN {r[1]} · TAC {r[2]}", "cell selection", "info"
    if "Initial Registration is successful" in m:
        return "UE", "Registered · 5G standalone, normal service", "MM-REGISTERED", "ok"
    if r := re.search(r"TUN interface\[(\w+), ([\d.]+)\] is up", m):
        dnn = "edge" if r[2].startswith(EDGE_PREFIX) else "internet" if r[2].startswith(INTERNET_PREFIX) else "?"
        return "UE", f"Data tunnel up · {dnn} DNN · {r[2]}", f"{r[1]}", "ok"
    if "switching off" in m:
        return "UE", "Device switching off", "", "warn"
    if "MM-DEREGISTER-INITIATED" in m:
        return "UE", "Deregistration (switch-off) sent to network", "", "warn"
    return None


def _parse_gnb(m):
    if "NG Setup procedure is successful" in m:
        return "gNB", "Cell on air · NG Setup with AMF", "N2 / SCTP", "ok"
    if "RRC Setup for UE" in m:
        return "gNB", "Radio connection (RRC) set up for the phone", "", "info"
    if "PDU session resource(s) setup" in m:
        return "gNB", "Radio bearer set up for a data session", "N2 PDU Session Resource Setup", "info"
    if "Releasing RRC connection" in m:
        return "gNB", "Radio connection released", "", "warn"
    return None


def _parse_amf(m):
    if "Registration request" in m:
        return "AMF", "Registration request received", "identity concealed as SUCI", "info"
    if "Setup NF EndPoint" in m and "nausf-handler" in m:
        return "AUSF", "Authentication (5G-AKA) · SIM verified", "AMF → AUSF", "info"
    if "Setup NF EndPoint" in m and "nudm-handler" in m:
        return "UDM", "Subscription profile fetched", "AMF → UDM", "info"
    if "Setup NF EndPoint" in m and "npcf-handler" in m:
        return "PCF", "Access & mobility policy applied", "AMF → PCF", "info"
    if r := re.search(r"\[(imsi-\d+)\] Registration complete", m):
        return "AMF", "Registration complete", r[1], "ok"
    if r := re.search(r"UE SUPI\[imsi-\d+\] DNN\[(\w+)\]", m):
        return "AMF", f"Data session requested · {r[1]} DNN", "N11 → SMF", "info"
    if "Deregistration request" in m:
        return "AMF", "Deregistration request · phone switching off", "", "warn"
    if "UE Context Release" in m:
        return "AMF", "UE context released", "", "warn"
    return None


def _parse_smf(m):
    if r := re.search(r"UE SUPI\[imsi-\d+\] DNN\[(\w+)\] IPv4\[([\d.]+)\]", m):
        return "SMF", f"IP {r[2]} assigned · {r[1]} DNN", "session management", "ok"
    if r := re.search(r"Removed Session: .*DNN:\[(\w+):\d+\] IPv4:\[([\d.]+)\]", m):
        return "SMF", f"Session released · {r[1]} DNN · {r[2]}", "", "warn"
    return None


def _parse_upf(m):
    if r := re.search(r"APN\[(\w+)\] PDN-Type\[\d+\] IPv4\[([\d.]+)\]", m):
        how = "local breakout, no NAT" if r[1] == "edge" else "NAT to the outside"
        return "UPF", f"User-plane path installed · {r[1]} DNN", f"PFCP rules for {r[2]} · {how}", "ok"
    return None


LOG_SOURCES = {UE: _parse_ue, GNB: _parse_gnb, "open5gs-amf": _parse_amf, "open5gs-smf": _parse_smf, UPF: _parse_upf}


def _follow_logs(name, parser):
    # Polls with a moving `since` rather than a follow stream: follow streams
    # end (and don't resume) when the container restarts, which is exactly
    # when the interesting attach events happen.
    last = time.time()
    while True:
        try:
            c = dk.containers.get(name)
            out = c.logs(since=last, timestamps=True).decode(errors="replace")
            for line in out.splitlines():
                stamp, _, msg = line.partition(" ")
                try:
                    ts = datetime.fromisoformat(stamp[:26] + "+00:00").timestamp()
                except ValueError:
                    continue
                if ts <= last:
                    continue
                last = ts
                parsed = parser(ANSI.sub("", msg))
                if parsed:
                    emit(*parsed, ts=ts)
        except docker.errors.NotFound:
            pass
        except Exception:
            log.exception("log follower %s", name)
        time.sleep(0.5)


# --------------------------------------------------------------- UE control

def _container(name):
    try:
        return dk.containers.get(name)
    except docker.errors.NotFound:
        return None


def ue_sh(cmd, timeout=6):
    c = _container(UE)
    if not c or c.status != "running":
        return 1, ""
    code, out = c.exec_run(["timeout", str(timeout), "sh", "-c", cmd])
    return code, out.decode(errors="replace")


def ue_detach(cmd):
    c = _container(UE)
    if c and c.status == "running":
        c.exec_run(["sh", "-c", cmd], detach=True)


def nr(cmd):
    # Stale proc-table entries from earlier container runs all claim PID 1,
    # so nr-cli may pick a dead one and hang — keep only the newest.
    code, out = ue_sh(
        "cd /tmp/UERANSIM.proc-table 2>/dev/null && ls -t | tail -n +2 | xargs -r rm -f; "
        f"nr-cli {UE_IMSI} -e '{cmd}'",
        timeout=5,
    )
    return out if code == 0 else ""


def ue_tunnels():
    code, out = ue_sh("ip -4 -o addr show")
    tun = {}
    for line in out.splitlines():
        if r := re.search(r"\d+: (uesimtun\d+)\s+inet ([\d.]+)/", line):
            dnn = "edge" if r[2].startswith(EDGE_PREFIX) else "internet" if r[2].startswith(INTERNET_PREFIX) else r[1]
            tun[dnn] = {"if": r[1], "ip": r[2]}
    return tun


def ue_status():
    status = {}
    for line in nr("status").splitlines():
        k, _, v = line.partition(":")
        if v.strip():
            status[k.strip()] = v.strip()
    return status


def ensure_routes(tun):
    cmds = []
    if "edge" in tun:
        cmds.append(f"ip route replace {EDGE_NODE_IP}/32 dev {tun['edge']['if']}")
    if "internet" in tun:
        cmds.append(f"ip route replace {CENTRAL_BIND_IP}/32 dev {tun['internet']['if']}")
    if cmds:
        ue_sh("; ".join(cmds))


def ffmpeg_running():
    code, out = ue_sh(f"pgrep -af '{FFMPEG_MATCH}'")
    return out.strip() if code == 0 else ""


def stop_stream():
    ue_sh(f"pkill -f '{FFMPEG_MATCH}' || true")


def _copy_video_to_ue(name):
    path = os.path.join(MEDIA_DIR, name)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        tar.add(path, arcname=name)
    ue_sh("mkdir -p /tmp/cam")
    _container(UE).put_archive("/tmp/cam", buf.getvalue())


def start_stream():
    ensure_ffmpeg()
    video, mode = desired["video"], desired["mode"]
    if mode == "edge":
        url = f"rtsp://{EDGE_NODE_IP}:{RTSP_NODEPORT}/stream"
    else:
        url = f"rtsp://{CENTRAL_BIND_IP}:{CENTRAL_RTSP_PORT}/stream"
    if video == TEST_PATTERN:
        src = "-re -f lavfi -i testsrc2=size=1280x720:rate=25"
    else:
        _copy_video_to_ue(video)
        src = f"-re -stream_loop -1 -i /tmp/cam/{video}"
    stop_stream()
    ue_detach(
        f"exec ffmpeg -nostdin -loglevel error {src} -an -vf 'scale=w=min(1280\\,iw):h=-2' "
        "-r 30 -c:v libx264 -preset veryfast -tune zerolatency -g 30 -pix_fmt yuv420p "
        f"-f rtsp -rtsp_transport tcp {url} > /tmp/cam-ffmpeg.log 2>&1"
    )


def _run_op(name, fn):
    if not op_lock.acquire(blocking=False):
        raise HTTPException(409, f"busy: {op['name']}")

    def runner():
        op.update(name=name, started=time.time(), error=None)
        try:
            fn()
        except Exception as e:
            log.exception("op %s", name)
            op["error"] = str(e)
            emit("PORTAL", f"{name} failed", str(e), "warn")
        finally:
            op["name"] = None
            op_lock.release()

    threading.Thread(target=runner, daemon=True).start()


def _wait(pred, timeout, step=0.5):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(step)
    return False


def power_on(reason="Device powered on", reset_cell=False):
    ue = _container(UE)
    ue.update(restart_policy={"Name": "unless-stopped"})
    if reset_cell:
        _reset_cell_and_boot(ue, reason)
    else:
        emit("PORTAL", reason, "the phone boots and searches for the network", "info")
        ue.reload()
        if ue.status == "running":
            ue.restart(timeout=3)
        else:
            ue.start()
        if not _wait(lambda: len(ue_tunnels()) >= 2, 12):
            _reset_cell_and_boot(ue, "Phone could not attach — resetting the cell")
    ensure_routes(ue_tunnels())
    if desired["camera"]:
        start_stream()
        emit("UE", "Camera streaming resumed", desired["video"], "ok")


def _reset_cell_and_boot(ue, reason):
    # Repeated UE churn leaves ghost UE contexts in UERANSIM's gNB (see
    # ran/rls-watchdog.sh); a fresh cell is the reliable recovery. The phone
    # must boot only after the new cell broadcasts system info, or it fails
    # cell selection and waits ~10s before retrying.
    emit("PORTAL", reason, "gNB restarted, then the phone boots", "warn")
    ue.stop(timeout=2)
    _container(GNB).restart(timeout=3)
    time.sleep(4)
    ue.start()
    if not _wait(lambda: len(ue_tunnels()) >= 2, 25):
        raise RuntimeError("phone did not get both data sessions within 25s")


def power_off():
    stop_stream()
    ue = _container(UE)
    if not ue or ue.status != "running":
        return
    # Otherwise Docker's unless-stopped policy reboots the "switched off" phone.
    ue.update(restart_policy={"Name": "no"})
    emit("PORTAL", "Power button pressed", "UE sends a switch-off deregistration", "info")
    nr("deregister switch-off")
    if not _wait(lambda: (ue.reload() or ue.status) != "running", 8):
        ue.stop(timeout=3)


def ensure_ffmpeg():
    if ue_sh("command -v ffmpeg")[0] == 0:
        return
    emit("PORTAL", "Installing the camera app on the phone", "ffmpeg inside the UE container — one-off, ~1 min", "info")
    code, out = ue_sh("apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ffmpeg >/dev/null", timeout=300)
    if code != 0:
        raise RuntimeError("ffmpeg install failed: " + out[-200:])


def camera(on):
    if on:
        tun = ue_tunnels()
        if not tun:
            raise RuntimeError("phone is not attached")
        ensure_routes(tun)
        start_stream()
        path = "edge DNN (local breakout)" if desired["mode"] == "edge" else "internet DNN → central cloud"
        emit("UE", "Camera streaming", f"{desired['video']} via {path}", "ok")
    else:
        stop_stream()
        emit("UE", "Camera stopped", "", "info")


def switch_mode(mode):
    desired["mode"] = mode
    save_desired()
    if mode == "edge":
        emit("PORTAL", "Path → edge breakout", "video uses the edge DNN straight to the local edge site", "ok")
    else:
        emit("PORTAL", "Path → central cloud", f"internet DNN, NAT'd at the UPF, +{desired['wan_delay_ms']} ms WAN each way (emulated)", "info")
    if desired["camera"] and ue_tunnels():
        start_stream()


# ------------------------------------------------------ central-cloud relay

async def _pump(reader, writer, loop):
    q: asyncio.Queue = asyncio.Queue()

    async def sender():
        while True:
            due, data = await q.get()
            if data is None:
                break
            wait = due - loop.time()
            if wait > 0:
                await asyncio.sleep(wait)
            writer.write(data)
            await writer.drain()

    task = asyncio.create_task(sender())
    try:
        while data := await reader.read(65536):
            q.put_nowait((loop.time() + desired["wan_delay_ms"] / 1000, data))
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    q.put_nowait((0, None))
    try:
        await task
    except ConnectionError:
        pass
    writer.close()


def _relay_handler(target_port, label):
    async def handle(reader, writer):
        loop = asyncio.get_running_loop()
        peer = writer.get_extra_info("peername")[0]
        try:
            up_r, up_w = await asyncio.open_connection(EDGE_NODE_IP, target_port)
        except OSError:
            writer.close()
            return
        if label == "rtsp":
            relay_clients[peer] = time.time()
            emit("CLOUD", "Stream reached the central cloud", f"from {peer} — the UPF's NAT address, not the phone's", "info")
        await asyncio.gather(_pump(reader, up_w, loop), _pump(up_r, writer, loop), return_exceptions=True)
        if label == "rtsp":
            relay_clients.pop(peer, None)

    return handle


async def _relay_supervisor():
    servers = []
    while not servers:
        try:
            servers = [
                await asyncio.start_server(_relay_handler(RTSP_NODEPORT, "rtsp"), CENTRAL_BIND_IP, CENTRAL_RTSP_PORT),
                await asyncio.start_server(_relay_handler(INGEST_NODEPORT, "probe"), CENTRAL_BIND_IP, CENTRAL_PROBE_PORT),
            ]
            log.info("central-cloud relay listening on %s:%s/%s", CENTRAL_BIND_IP, CENTRAL_RTSP_PORT, CENTRAL_PROBE_PORT)
        except OSError as e:
            for s in servers:
                s.close()
            servers = []
            log.warning("relay bind failed (%s), retrying in 10s", e)
            await asyncio.sleep(10)


# ----------------------------------------------------------------- polling

def _prom(url):
    out = {}
    try:
        for line in httpx.get(url, timeout=2).text.splitlines():
            if line and not line.startswith("#"):
                k, _, v = line.rpartition(" ")
                out[k] = float(v)
    except Exception:
        pass
    return out


def _probe(url):
    code, out = ue_sh(f"curl -s -o /dev/null -w '%{{time_connect}} %{{time_starttransfer}}' --max-time 2 {url}", timeout=4)
    try:
        conn, ttfb = (float(x) for x in out.split())
        return round((ttfb - conn) * 1000, 1) if ttfb > 0 else None
    except ValueError:
        return None


def _upf_throughput():
    c = _container(UPF)
    if not c or c.status != "running":
        return {}
    cmd = " ; ".join(f"cat /sys/class/net/{i}/statistics/rx_bytes" for i in UPF_TUN.values())
    code, out = c.exec_run(["sh", "-c", cmd])
    vals = [int(x) for x in out.decode().split() if x.isdigit()]
    if len(vals) != len(UPF_TUN):
        return {}
    now, cur = time.time(), dict(zip(UPF_TUN.keys(), vals))
    rates = {}
    if upf_prev["t"]:
        dt = now - upf_prev["t"]
        rates = {k: round(max(0, cur[k] - upf_prev["bytes"].get(k, cur[k])) * 8 / dt / 1e6, 2) for k in cur}
    upf_prev.update(t=now, bytes=cur)
    return {"uplink_mbps": rates, "total_bytes": cur}


def _poll_once():
    containers = {}
    for c in dk.containers.list(all=True, filters={"name": ["open5gs-", "ueransim-"]}):
        containers[c.name] = c.status
    ue_up = containers.get(UE) == "running"
    status = ue_status() if ue_up else {}
    tun = ue_tunnels() if ue_up else {}
    amf, smf, upf = (_prom(CORE_METRICS[k]) for k in ("amf", "smf", "upf"))
    try:
        ingest = httpx.get(f"{INGEST_URL}/api/state", timeout=2).json()
    except Exception:
        ingest = None
    snapshot.update(
        ts=time.time(),
        containers=containers,
        ue={
            "running": ue_up,
            "registered": status.get("rm-state") == "RM-REGISTERED",
            "status": status,
            "tunnels": tun,
            "streaming": bool(ffmpeg_running()) if ue_up else False,
        },
        core={
            "gnbs": amf.get("gnb"), "ran_ues": amf.get("ran_ue"), "amf_sessions": amf.get("amf_session"),
            "reg_requests": amf.get("fivegs_amffunction_rm_reginitreq"), "reg_success": amf.get("fivegs_amffunction_rm_reginitsucc"),
            "auth_requests": amf.get("fivegs_amffunction_amf_authreq"), "ues_active": smf.get("ues_active"),
            "sessions": smf.get("pfcp_sessions_active"), "upf_sessions": upf.get("fivegs_upffunction_upf_sessionnbr"),
            "qos_flows": {k.split('"')[1]: v for k, v in upf.items() if k.startswith("fivegs_upffunction_upf_qosflows{")},
        },
        upf=_upf_throughput(),
        ingest=ingest,
        relay={"clients": list(relay_clients)},
    )


def _probe_loop():
    while True:
        if snapshot.get("ue", {}).get("tunnels") and not op["name"]:
            e = _probe(f"http://{EDGE_NODE_IP}:{INGEST_NODEPORT}/healthz")
            c = _probe(f"http://{CENTRAL_BIND_IP}:{CENTRAL_PROBE_PORT}/healthz")
            probe.update(edge_ms=e, central_ms=c, last=time.time())
            # Radio health: ICMP to the edge node over the edge tunnel. Unlike
            # the HTTP probes above it doesn't depend on any pod being up, so
            # an app restart is never mistaken for a radio stall.
            edge_if = snapshot["ue"]["tunnels"].get("edge", {}).get("if")
            alive = bool(edge_if) and ue_sh(f"ping -c1 -W1 -I {edge_if} {EDGE_NODE_IP}", timeout=3)[0] == 0
            probe["edge_fail"] = 0 if alive else probe["edge_fail"] + 1
            # UERANSIM's RLS data path can stall for good after a while
            # (upstream issue #757, ran/rls-watchdog.sh) — re-attach.
            if probe["edge_fail"] >= 3 and not op["name"]:
                probe["edge_fail"] = 0
                emit("PORTAL", "Radio link stalled — re-attaching the phone", "known UERANSIM simulator bug; auto-recovery", "warn")
                try:
                    _run_op("Re-attach", lambda: power_on("Re-attaching after radio stall", reset_cell=True))
                except HTTPException:
                    pass
        time.sleep(3)


def _reconcile_loop():
    while True:
        try:
            _poll_once()
            ue = snapshot["ue"]
            if not op["name"] and ue["running"] and ue["tunnels"]:
                ensure_routes(ue["tunnels"])
                if desired["camera"] and not ue["streaming"] and time.time() >= restart_backoff["until"]:
                    restart_backoff["n"] += 1
                    if restart_backoff["n"] > 1:
                        _, err = ue_sh("tail -n 2 /tmp/cam-ffmpeg.log")
                        emit("UE", "Camera stream dropped — restarting", err.strip()[-160:], "warn")
                    restart_backoff["until"] = time.time() + min(30, 2 ** restart_backoff["n"])
                    start_stream()
                elif ue["streaming"]:
                    restart_backoff.update(n=0, until=0)
                elif not desired["camera"] and ue["streaming"]:
                    stop_stream()
        except Exception:
            log.exception("reconcile")
        time.sleep(2)


def _adopt_current_state():
    cmd = ffmpeg_running()
    if cmd:
        desired["camera"] = True
        desired["mode"] = "central" if f":{CENTRAL_RTSP_PORT}/" in cmd else "edge"
        if r := re.search(r"/tmp/(?:cam/)?([\w.-]+\.\w+)", cmd):
            desired["video"] = r[1] if os.path.exists(os.path.join(MEDIA_DIR, r[1])) else desired["video"]


@asynccontextmanager
async def lifespan(app: FastAPI):
    load_desired()
    _adopt_current_state()
    for name, parser in LOG_SOURCES.items():
        threading.Thread(target=_follow_logs, args=(name, parser), daemon=True).start()
    threading.Thread(target=_reconcile_loop, daemon=True).start()
    threading.Thread(target=_probe_loop, daemon=True).start()
    relay = asyncio.create_task(_relay_supervisor())
    emit("PORTAL", "Lab portal online", "watching UE, gNB, AMF, SMF and UPF", "info")
    yield
    relay.cancel()


app = FastAPI(lifespan=lifespan)


# --------------------------------------------------------------------- API

@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC_DIR, "index.html"))


@app.get("/api/state")
def api_state():
    return {**snapshot, "desired": desired, "op": op, "probe": probe, "videos": _videos()}


@app.get("/api/events")
async def api_events(request: Request, after: int = 0):
    async def gen():
        last, idle = after, 0
        while not await request.is_disconnected():
            with _event_lock:
                new = [e for e in EVENTS if e["id"] > last]
            for e in new:
                last = e["id"]
                yield f"data: {json.dumps(e)}\n\n"
            idle = 0 if new else idle + 1
            if idle >= 60:
                idle = 0
                yield ": keepalive\n\n"
            await asyncio.sleep(0.25)

    return StreamingResponse(gen(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})


@app.post("/api/ue/power")
async def api_power(body: dict):
    _run_op("Power on" if body.get("on") else "Power off", power_on if body.get("on") else power_off)
    return JSONResponse({"ok": True}, status_code=202)


@app.post("/api/ue/camera")
async def api_camera(body: dict):
    video = body.get("video", desired["video"])
    if video != TEST_PATTERN and video not in _videos():
        raise HTTPException(404, "unknown video")
    desired["video"] = video
    desired["camera"] = bool(body.get("on"))
    save_desired()
    _run_op("Camera", lambda: camera(desired["camera"]))
    return JSONResponse({"ok": True}, status_code=202)


@app.post("/api/path")
async def api_path(body: dict):
    mode = body.get("mode")
    if mode not in ("edge", "central"):
        raise HTTPException(400, "mode must be edge or central")
    if "wan_delay_ms" in body:
        desired["wan_delay_ms"] = max(0, min(200, int(body["wan_delay_ms"])))
        save_desired()
    if mode != desired["mode"]:
        _run_op("Path switch", lambda: switch_mode(mode))
    return {"ok": True}


@app.post("/api/wan-delay")
async def api_wan_delay(body: dict):
    desired["wan_delay_ms"] = max(0, min(200, int(body.get("ms", 25))))
    save_desired()
    emit("CLOUD", f"WAN delay set to {desired['wan_delay_ms']} ms each way", "emulated distance to the central cloud", "info")
    return {"ok": True}


def _videos():
    try:
        return sorted(f for f in os.listdir(MEDIA_DIR) if f.lower().endswith(VIDEO_EXTS) and not f.startswith("."))
    except FileNotFoundError:
        return []


def _safe_media_path(name):
    if not re.fullmatch(r"[\w.-]+", name) or name not in _videos():
        raise HTTPException(404, "not found")
    return os.path.join(MEDIA_DIR, name)


@app.get("/media/{name}")
def media(name: str):
    return FileResponse(_safe_media_path(name))


@app.post("/api/videos")
async def upload(file: UploadFile):
    base = re.sub(r"[^\w.-]", "_", os.path.basename(file.filename or ""))[:80]
    if not base.lower().endswith(VIDEO_EXTS):
        raise HTTPException(400, f"allowed: {', '.join(VIDEO_EXTS)}")
    dest, size = os.path.join(MEDIA_DIR, base), 0
    tmp = dest + ".part"
    with open(tmp, "wb") as f:
        while chunk := await file.read(1 << 20):
            size += len(chunk)
            if size > MAX_UPLOAD_BYTES:
                f.close()
                os.remove(tmp)
                raise HTTPException(413, "max 300 MB")
            f.write(chunk)
    os.replace(tmp, dest)
    emit("PORTAL", "Video uploaded to the phone's gallery", f"{base} · {size / 1e6:.1f} MB", "info")
    return {"ok": True, "name": base}


@app.get("/api/ingest/stream.mjpg")
async def ingest_stream():
    client = httpx.AsyncClient(timeout=None)
    try:
        req = client.build_request("GET", f"{INGEST_URL}/stream.mjpg")
        resp = await client.send(req, stream=True)
    except httpx.HTTPError:
        await client.aclose()
        raise HTTPException(502, "edge ingest unreachable")

    async def body():
        try:
            async for chunk in resp.aiter_raw():
                yield chunk
        finally:
            await resp.aclose()
            await client.aclose()

    return StreamingResponse(body(), media_type=resp.headers.get("content-type", "multipart/x-mixed-replace; boundary=frame"))
