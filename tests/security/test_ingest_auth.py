"""edge-ingest: access-token checks on its API (tests/security/run.sh)."""
import base64, hashlib, importlib.util, os, subprocess, sys, types
R, W = sys.argv[1], sys.argv[2]
P = f"{W}/.edge-pki"
cv2 = types.ModuleType("cv2")
cv2.imencode = lambda ext, frame, *a: (True, types.SimpleNamespace(tobytes=lambda: b"jpg"))
sys.modules["cv2"] = cv2
ul = types.ModuleType("ultralytics"); ul.YOLO = object
sys.modules["ultralytics"] = ul
os.environ.update(SIGNING_KEY_FILE=f"{P}/jwt/signing.pem", KID_FILE=f"{P}/jwt/kid", VLM_API_KEY="vk")
sys.path.insert(0, f"{R}/edge/authz")
import app as authz  # to mint real tokens
import jwt
spec = importlib.util.spec_from_file_location("ingest_app", f"{R}/edge/ingest/app.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
keyset = jwt.PyJWKSet.from_json(open(f"{P}/jwt/jwks.json").read())
class LocalJWKS:
    def get_signing_key_from_jwt(self, t):
        kid = jwt.get_unverified_header(t).get("kid")
        found = [k for k in keyset.keys if k.key_id == kid]
        if not found:
            raise jwt.PyJWKClientError(f'Unable to find a signing key that matches: "{kid}"')
        return found[0]
m._jwks = LocalJWKS()
from fastapi.testclient import TestClient
c = TestClient(m.app)

def der_hash(i):
    return hashlib.sha256(subprocess.check_output(["openssl", "x509", "-in", f"{P}/clients/{i}.crt", "-outform", "DER"])).hexdigest()
portal_hash = der_hash("lab-portal")
portal_tok = authz.issue("lab-portal", {"kind": "operator"}, {"ingest.read", "ai.ask"}, portal_hash)
prom_tok = authz.issue("prometheus", {"kind": "service"}, {"metrics.read"})
ue_tok = authz.issue("eec-ue1", {"kind": "ue"}, {"video.publish"}, der_hash("eec-ue1"))
xf = lambda h: {"x-forwarded-client-cert": f'Hash={h};Subject="CN=x"'}
B = lambda t: {"Authorization": f"Bearer {t}"}
checks = [
  ("healthz public", c.get("/healthz").status_code, 200),
  ("page shell public", c.get("/").status_code, 200),
  ("state, no token -> 401", c.get("/api/state").status_code, 401),
  ("state, garbage token -> 401", c.get("/api/state", headers=B("abc.def.ghi")).status_code, 401),
  ("portal token + its cert -> 200", c.get("/api/state", headers={**B(portal_tok), **xf(portal_hash)}).status_code, 200),
  ("portal token without cert (stolen) -> 401", c.get("/api/state", headers=B(portal_tok)).status_code, 401),
  ("portal token with UE1's cert -> 401", c.get("/api/state", headers={**B(portal_tok), **xf(der_hash("eec-ue1"))}).status_code, 401),
  ("UE token (video.publish) on API -> 403", c.get("/api/state", headers={**B(ue_tok), **xf(der_hash("eec-ue1"))}).status_code, 403),
  ("prometheus token on /metrics -> 200", c.get("/metrics", headers=B(prom_tok)).status_code, 200),
  ("prometheus token on /api/state -> 403", c.get("/api/state", headers=B(prom_tok)).status_code, 403),
  ("portal token on /metrics -> 403", c.get("/metrics", headers={**B(portal_tok), **xf(portal_hash)}).status_code, 403),
  ("ask with ai.ask -> passes auth (409 no video)", c.post("/api/ask", json={"question": "x"}, headers={**B(portal_tok), **xf(portal_hash)}).status_code, 409),
  ("?token= for the demo page", c.get(f"/api/state?token={prom_tok}").status_code, 403),
]
# expired token
import time, json
exp_tok = jwt.encode({"iss": authz.ISSUER, "aud": authz.AUDIENCE, "sub": "prometheus", "exp": int(time.time()) - 5, "scope": "metrics.read"},
                     open(f"{P}/jwt/signing.pem").read(), algorithm="RS256", headers={"kid": open(f"{P}/jwt/kid").read()})
checks.append(("expired token -> 401", c.get("/metrics", headers=B(exp_tok)).status_code, 401))
# wrong audience
aud_tok = jwt.encode({"iss": authz.ISSUER, "aud": "other", "sub": "x", "exp": int(time.time()) + 60, "scope": "metrics.read"},
                     open(f"{P}/jwt/signing.pem").read(), algorithm="RS256", headers={"kid": open(f"{P}/jwt/kid").read()})
checks.append(("wrong audience -> 401", c.get("/metrics", headers=B(aud_tok)).status_code, 401))
# token signed by another key with same kid
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
evil = rsa.generate_private_key(public_exponent=65537, key_size=2048).private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
forged = jwt.encode({"iss": authz.ISSUER, "aud": authz.AUDIENCE, "sub": "x", "exp": int(time.time()) + 60, "scope": "metrics.read"},
                    evil, algorithm="RS256", headers={"kid": open(f"{P}/jwt/kid").read()})
checks.append(("forged signature -> 401", c.get("/metrics", headers=B(forged)).status_code, 401))
none_tok = jwt.encode({"iss": authz.ISSUER, "aud": authz.AUDIENCE, "sub": "x", "scope": "metrics.read"}, None, algorithm="none")
checks.append(("alg=none -> 401", c.get("/metrics", headers=B(none_tok)).status_code, 401))
# service token + VLM header
calls = []
class Resp:
    def __init__(self, j): self.j = j
    def raise_for_status(self): pass
    def json(self): return self.j
def fake_post(url, **kw):
    calls.append((url, kw))
    if url.endswith("/token"): return Resp({"access_token": "svc-tok", "expires_in": 600})
    return Resp({"choices": [{"message": {"content": "ok"}}]})
m.requests.post = fake_post
m.CLIENT_SECRET = "s"
checks.append(("service token via client credentials", m._service_token.get(), "svc-tok"))
checks.append(("token request uses basic auth", calls[0][1]["auth"], ("edge-ingest", "s")))
m._service_token.get(); checks.append(("token cached", len(calls), 1))
m._call_vlm(object()); checks.append(("vlm bearer (static key)", calls[-1][1]["headers"], {"Authorization": "Bearer vk"}))
bad = 0
for n, g, w in checks:
    ok = g == w; bad += not ok
    print("PASS" if ok else "FAIL", "ingest:", n, "" if ok else f"got={g!r} want={w!r}")
sys.exit(bad)
