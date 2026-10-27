"""edge-authz: OAuth 2.0 token endpoint checks (tests/security/run.sh)."""
import base64, hashlib, importlib.util, json, os, subprocess, sys
R, W = sys.argv[1], sys.argv[2]
P = f"{W}/.edge-pki"
T = f"{W}/authzt"
for d in ("secrets", "rev", "run"):
    os.makedirs(f"{T}/{d}", exist_ok=True)
open(f"{T}/secrets/edge-ingest", "w").write("s3cret-ingest")
open(f"{T}/secrets/prometheus", "w").write("prom")
open(f"{T}/rev/revoked", "w").write("")
import yaml
docs = list(yaml.safe_load_all(open(f"{R}/edge/manifests/authz.yaml")))
open(f"{T}/policy.yaml", "w").write(docs[0]["data"]["policy.yaml"])
os.environ.update(POLICY_FILE=f"{T}/policy.yaml", REVOKED_FILE=f"{T}/rev/revoked", RUNTIME_STATE_FILE=f"{T}/run/state.json",
                  SIGNING_KEY_FILE=f"{P}/jwt/signing.pem", KID_FILE=f"{P}/jwt/kid", JWKS_FILE=f"{P}/jwt/jwks.json",
                  CLIENT_SECRETS_DIR=f"{T}/secrets")
sys.path.insert(0, f"{R}/edge/authz")
import app as authz
import admin
import jwt
from fastapi.testclient import TestClient
c = TestClient(authz.app)

def der_hash(id_):
    der = subprocess.check_output(["openssl", "x509", "-in", f"{P}/clients/{id_}.crt", "-outform", "DER"])
    return hashlib.sha256(der).hexdigest()

def xfcc(id_, cn=None):
    return f'Hash={der_hash(id_)};Subject="CN={cn or id_},O=5G Edge AI Lab";URI=urn:edge-lab:eec:{id_}'

jwks = jwt.PyJWKSet.from_json(open(f"{P}/jwt/jwks.json").read())
def verify(tok):
    kid = jwt.get_unverified_header(tok)["kid"]
    key = [k for k in jwks.keys if k.key_id == kid][0]
    return jwt.decode(tok, key.key, algorithms=["RS256"], audience="edge-eas", issuer="https://edge.lab/authz")

checks = []
def chk(name, got, want): checks.append((name, got, want))
form = lambda **kw: {"grant_type": "client_credentials", **kw}

r = c.post("/token", data=form(client_id="eec-ue1"), headers={"x-forwarded-client-cert": xfcc("eec-ue1"), "x-forwarded-for": "10.47.0.2"})
chk("UE1 with its cert -> 200", r.status_code, 200)
claims = verify(r.json()["access_token"])
chk("sub", claims["sub"], "eec-ue1"); chk("gpsi", claims["gpsi"], "msisdn-999700000001")
chk("scope", claims["scope"], "video.publish")
chk("mediamtx perms: publish own path only", claims["mediamtx_permissions"], [{"action": "publish", "path": "ue/eec-ue1"}])
want_cnf = base64.urlsafe_b64encode(bytes.fromhex(der_hash("eec-ue1"))).rstrip(b"=").decode()
chk("cert-bound (cnf x5t#S256)", claims["cnf"], {"x5t#S256": want_cnf})
chk("ttl 600", claims["exp"] - claims["iat"], 600)
chk("UE1 without cert -> 401", c.post("/token", data=form(client_id="eec-ue1")).status_code, 401)
chk("UE2's cert claiming UE1 -> 401", c.post("/token", data=form(client_id="eec-ue1"), headers={"x-forwarded-client-cert": xfcc("eec-ue2")}).status_code, 401)
chk("UE1 asks for scope it lacks -> 400", c.post("/token", data=form(client_id="eec-ue1", scope="video.read"), headers={"x-forwarded-client-cert": xfcc("eec-ue1")}).status_code, 400)
chk("unknown client -> 401", c.post("/token", data=form(client_id="mallory"), headers={"x-forwarded-client-cert": xfcc("eec-ue1", "mallory")}).status_code, 401)
chk("wrong grant -> 400", c.post("/token", data={"grant_type": "password"}).status_code, 400)
b = base64.b64encode(b"edge-ingest:s3cret-ingest").decode()
r = c.post("/token", data=form(), headers={"Authorization": f"Basic {b}"})
chk("ingest basic auth -> 200", r.status_code, 200)
ci = verify(r.json()["access_token"])
chk("ingest perms", ci["mediamtx_permissions"], [{"action": "read", "path": "~^ue/"}, {"action": "api"}])
chk("ingest token not cert-bound", "cnf" in ci, False)
chk("prometheus client_secret_post -> 200", c.post("/token", data=form(client_id="prometheus", client_secret="prom")).status_code, 200)
chk("ingest bad secret -> 401", c.post("/token", data=form(client_id="edge-ingest", client_secret="nope")).status_code, 401)
chk("secret client can't use a cert instead -> 401", c.post("/token", data=form(client_id="edge-ingest"), headers={"x-forwarded-client-cert": xfcc("eec-ue1", "edge-ingest")}).status_code, 401)
chk("cert client can't use a secret -> 401", c.post("/token", data=form(client_id="eec-ue1", client_secret="x")).status_code, 401)
# revocation via ConfigMap file
open(f"{T}/rev/revoked", "w").write("eec-ue2")
chk("UE2 revoked (configmap) -> 401", c.post("/token", data=form(client_id="eec-ue2"), headers={"x-forwarded-client-cert": xfcc("eec-ue2")}).status_code, 401)
chk("UE1 unaffected -> 200", c.post("/token", data=form(client_id="eec-ue1"), headers={"x-forwarded-client-cert": xfcc("eec-ue1")}).status_code, 200)
# runtime restore overrides the (not yet refreshed) configmap
admin._write({"revoked": set(), "restored": {"eec-ue2"}})
chk("UE2 restored at runtime -> 200", c.post("/token", data=form(client_id="eec-ue2"), headers={"x-forwarded-client-cert": xfcc("eec-ue2")}).status_code, 200)
open(f"{T}/rev/revoked", "w").write("")
admin._write({"revoked": {"eec-ue1"}, "restored": set()})
chk("UE1 revoked at runtime -> 401", c.post("/token", data=form(client_id="eec-ue1"), headers={"x-forwarded-client-cert": xfcc("eec-ue1")}).status_code, 401)
os.remove(f"{T}/run/state.json")
chk("jwks served", c.get("/jwks.json").json()["keys"][0]["kid"], open(f"{P}/jwt/kid").read())
chk("no docs/openapi", c.get("/openapi.json").status_code, 404)
bad = 0
for n, g, w in checks:
    ok = g == w; bad += not ok
    print("PASS" if ok else "FAIL", "authz:", n, "" if ok else f"got={g!r} want={w!r}")
sys.exit(bad)
