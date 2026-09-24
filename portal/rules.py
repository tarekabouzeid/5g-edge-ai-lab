"""
Alert rules evaluated against the edge AI's live output.

Three rule types:
  zone   — an object of a class has its "feet" (bottom-centre of its box)
           inside a rectangle drawn on the video (normalized 0..1 coords)
  count  — at least N objects of a class are in view
  ask    — a yes/no question put to the vision-language model every N
           seconds; the rule is active while the answer starts with "yes"

A rule fires once on the transition to active, stays active until the
condition has been false for RELEASE_CHECKS evaluations in a row, and
never fires again within COOLDOWN_S — so it alerts on events, not frames.
"""
import json
import threading
import time
import uuid
from collections import deque

import httpx

RELEASE_CHECKS = 3
COOLDOWN_S = 10
EVAL_PERIOD_S = 0.5
MAX_RULES = 20


class RuleError(ValueError):
    pass


def _clean_rule(spec, existing=None):
    r = dict(existing or {})
    kind = spec.get("type", r.get("type"))
    if kind not in ("zone", "count", "ask"):
        raise RuleError("type must be zone, count or ask")
    r["type"] = kind
    r["enabled"] = bool(spec.get("enabled", r.get("enabled", True)))
    if kind in ("zone", "count"):
        cls = str(spec.get("cls", r.get("cls", "person"))).strip().lower()[:30]
        if not cls:
            raise RuleError("object class is required")
        r["cls"] = cls
    if kind == "count":
        n = int(spec.get("threshold", r.get("threshold", 1)))
        if not 1 <= n <= 50:
            raise RuleError("threshold must be 1..50")
        r["threshold"] = n
    if kind == "zone":
        z = [float(v) for v in spec.get("zone", r.get("zone", []))]
        if len(z) != 4 or not all(0 <= v <= 1 for v in z) or z[2] - z[0] < 0.02 or z[3] - z[1] < 0.02:
            raise RuleError("zone must be [x1, y1, x2, y2] within 0..1")
        r["zone"] = [round(v, 4) for v in z]
    if kind == "ask":
        q = str(spec.get("question", r.get("question", ""))).strip()[:200]
        if not q:
            raise RuleError("question is required")
        r["question"] = q
        every = int(spec.get("interval", r.get("interval", 8)))
        if not 5 <= every <= 120:
            raise RuleError("interval must be 5..120 s")
        r["interval"] = every
    default = {
        "zone": f"{r.get('cls', '').capitalize()} in zone",
        "count": f"{r.get('threshold')}+ {r.get('cls')} in view",
        "ask": r.get("question", "")[:40],
    }[kind]
    r["name"] = str(spec.get("name") or r.get("name") or default).strip()[:60]
    return r


DEFAULT_RULES = [
    {"type": "ask", "name": "Missing hard hat", "enabled": False, "interval": 8,
     "question": "Is there a person in this image who is not wearing a hard hat?"},
    {"type": "count", "name": "Crowding", "enabled": False, "cls": "person", "threshold": 3},
]


class RuleEngine:
    def __init__(self, ingest_url, rules_file, on_alert=None):
        self.ingest_url = ingest_url
        self.rules_file = rules_file
        self.on_alert = on_alert or (lambda alert: None)
        self.lock = threading.Lock()
        self.rules: list[dict] = []
        self.state: dict[str, dict] = {}
        self.alerts: deque = deque(maxlen=30)
        self.snapshots: dict[str, bytes] = {}
        self.asks: deque = deque(maxlen=12)
        self._load()

    # ------------------------------------------------------------ storage
    def _load(self):
        try:
            with open(self.rules_file) as f:
                specs = json.load(f)
        except (OSError, ValueError):
            specs = DEFAULT_RULES
        for spec in specs:
            try:
                self.rules.append({**_clean_rule(spec), "id": spec.get("id") or uuid.uuid4().hex[:8]})
            except (RuleError, TypeError, ValueError):
                pass
        self._save()

    def _save(self):
        try:
            with open(self.rules_file, "w") as f:
                json.dump(self.rules, f, indent=1)
        except OSError:
            pass

    # ---------------------------------------------------------------- CRUD
    def add(self, spec):
        with self.lock:
            if len(self.rules) >= MAX_RULES:
                raise RuleError(f"at most {MAX_RULES} rules")
            rule = {**_clean_rule(spec), "id": uuid.uuid4().hex[:8]}
            self.rules.append(rule)
            self._save()
            return rule

    def update(self, rid, patch):
        with self.lock:
            for i, r in enumerate(self.rules):
                if r["id"] == rid:
                    self.rules[i] = {**_clean_rule(patch, r), "id": rid}
                    if not self.rules[i]["enabled"]:
                        self.state.pop(rid, None)
                    self._save()
                    return self.rules[i]
        raise KeyError(rid)

    def delete(self, rid):
        with self.lock:
            before = len(self.rules)
            self.rules = [r for r in self.rules if r["id"] != rid]
            self.state.pop(rid, None)
            self._save()
            if len(self.rules) == before:
                raise KeyError(rid)

    def clear_alerts(self):
        with self.lock:
            self.alerts.clear()
            self.snapshots.clear()

    def public(self):
        with self.lock:
            rules = [{**r, "active": self.state.get(r["id"], {}).get("active", False),
                      "last_answer": self.state.get(r["id"], {}).get("last_answer")} for r in self.rules]
            return {"rules": rules, "alerts": list(self.alerts), "asks": list(self.asks)}

    # ----------------------------------------------------------------- ask
    def ask(self, question, record=True):
        resp = httpx.post(f"{self.ingest_url}/api/ask", json={"question": question}, timeout=45)
        if resp.status_code != 200:
            raise RuleError(resp.json().get("detail", "ask failed") if resp.headers.get("content-type", "").startswith("application/json") else "ask failed")
        out = resp.json()
        if record:
            with self.lock:
                self.asks.appendleft({"q": question, **out})
        return out

    # ---------------------------------------------------------- evaluation
    def _set(self, rule, cond, detail):
        st = self.state.setdefault(rule["id"], {"active": False, "clear": 0, "last_alert": 0})
        if cond:
            st["clear"] = 0
            if not st["active"]:
                st["active"] = True
                if time.time() - st["last_alert"] >= COOLDOWN_S:
                    st["last_alert"] = time.time()
                    return detail
        elif st["active"]:
            st["clear"] += 1
            if st["clear"] >= RELEASE_CHECKS:
                st["active"] = False
        return None

    def _fire(self, rule, detail):
        alert = {"id": uuid.uuid4().hex[:10], "rule_id": rule["id"], "name": rule["name"], "type": rule["type"],
                 "ts": time.time(), "detail": detail, "snapshot": False}
        try:
            snap = httpx.get(f"{self.ingest_url}/frame.jpg", timeout=3)
            if snap.status_code == 200:
                alert["snapshot"] = True
                self.snapshots[alert["id"]] = snap.content
        except httpx.HTTPError:
            pass
        with self.lock:
            self.alerts.appendleft(alert)
            live = {a["id"] for a in self.alerts}
            for k in [k for k in self.snapshots if k not in live]:
                del self.snapshots[k]
        self.on_alert(alert)

    def _eval_vision(self, ingest):
        live = bool(ingest and ingest.get("connected") and ingest.get("ingest_fps", 0) > 0)
        boxes = (ingest or {}).get("boxes") or []
        labels = (ingest or {}).get("labels") or {}
        with self.lock:
            rules = [r for r in self.rules if r["enabled"] and r["type"] in ("zone", "count")]
        for r in rules:
            if not live:
                cond, detail = False, ""
            elif r["type"] == "count":
                n = labels.get(r["cls"], 0)
                cond, detail = n >= r["threshold"], f"{n} × {r['cls']} in view (threshold {r['threshold']})"
            else:
                x1, y1, x2, y2 = r["zone"]
                inside = [b for b in boxes if b[4] == r["cls"] and x1 <= (b[0] + b[2]) / 2 <= x2 and y1 <= b[3] <= y2]
                cond, detail = bool(inside), f"{len(inside)} × {r['cls']} inside the zone"
            fired = self._set(r, cond, detail)
            if fired:
                self._fire(r, fired)

    def vision_loop(self):
        while True:
            try:
                ingest = httpx.get(f"{self.ingest_url}/api/state", timeout=2).json()
            except (httpx.HTTPError, ValueError):
                ingest = None
            try:
                self._eval_vision(ingest)
            except Exception:  # keep evaluating whatever one bad rule does
                pass
            time.sleep(EVAL_PERIOD_S)

    def ask_loop(self):
        due: dict[str, float] = {}
        while True:
            with self.lock:
                rules = [dict(r) for r in self.rules if r["enabled"] and r["type"] == "ask"]
            for r in rules:
                if time.time() < due.get(r["id"], 0):
                    continue
                due[r["id"]] = time.time() + r["interval"]
                try:
                    ans = self.ask(r["question"] + " Start your answer with yes or no.", record=False)["answer"]
                except (httpx.HTTPError, RuleError, ValueError):
                    continue
                with self.lock:
                    self.state.setdefault(r["id"], {"active": False, "clear": 0, "last_alert": 0})["last_answer"] = ans
                cond = ans.strip().lower().lstrip("\"'*").startswith("yes")
                # One ask per interval is slow feedback; release after a single "no".
                st = self.state[r["id"]]
                st["clear"] = RELEASE_CHECKS - 1 if cond is False and st["active"] else st["clear"]
                fired = self._set(r, cond, ans)
                if fired:
                    self._fire(r, fired)
            time.sleep(1)

    def start(self):
        threading.Thread(target=self.vision_loop, daemon=True).start()
        threading.Thread(target=self.ask_loop, daemon=True).start()
