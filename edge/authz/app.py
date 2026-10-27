"""
edge-authz: the lab's edge authorization server — the ECS/EES authorization
role of 3GPP TS 33.558, as a small OAuth 2.0 token endpoint (RFC 6749 client
credentials grant). See docs/security.md.

Client authentication:
  * tls_client_auth (RFC 8705) — phones (EECs) and the lab portal. Envoy
    terminates mutual TLS against the operator CA (and its CRL) and passes
    the verified certificate as an XFCC header (mode SanitizeSet, so a
    client-supplied XFCC never survives). The certificate's CN must equal
    the client_id. Tokens are bound to that certificate (cnf.x5t#S256).
  * client_secret_basic / client_secret_post — in-cluster service clients
    (edge-ingest, Prometheus), secrets from the edge-auth Secret.

Authorization: edge/authz/policy.yaml (scopes per client) minus the revoked
list (ConfigMap edge-authz-revoked, plus immediate revocations made through
admin.py). Tokens are RS256 JWTs carrying the granted scopes and, for the
RTSP gateway (mediamtx), the matching mediamtx_permissions — a phone may
publish only to ue/<its client_id>.
"""
import base64
import hmac
import json
import logging
import os
import re
import time
import uuid
from urllib.parse import unquote

import jwt
import yaml
from fastapi import FastAPI, Form, Request
from fastapi.responses import JSONResponse, Response

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("authz")

ISSUER = os.environ.get("ISSUER", "https://edge.lab/authz")
AUDIENCE = os.environ.get("AUDIENCE", "edge-eas")
TOKEN_TTL = int(os.environ.get("TOKEN_TTL_SECONDS", "600"))
POLICY_FILE = os.environ.get("POLICY_FILE", "/policy/policy.yaml")
REVOKED_FILE = os.environ.get("REVOKED_FILE", "/revoked/revoked")
# Immediate overrides from admin.py: {"revoked": [...], "restored": [...]}
RUNTIME_STATE = os.environ.get("RUNTIME_STATE_FILE", "/run/authz/state.json")
SIGNING_KEY = os.environ.get("SIGNING_KEY_FILE", "/keys/signing.pem")
KID_FILE = os.environ.get("KID_FILE", "/keys/kid")
JWKS_FILE = os.environ.get("JWKS_FILE", "/jwks/jwks")
SECRETS_DIR = os.environ.get("CLIENT_SECRETS_DIR", "/client-secrets")


def mediamtx_permissions(client_id, scopes):
    perms = []
    if "video.publish" in scopes:
        perms.append({"action": "publish", "path": f"ue/{client_id}"})
    if "video.read" in scopes:
        perms.append({"action": "read", "path": "~^ue/"})
    if "gateway.api" in scopes:
        perms.append({"action": "api"})
    return perms


def load_policy():
    with open(POLICY_FILE) as f:
        return yaml.safe_load(f)["clients"]


def runtime_state():
    try:
        with open(RUNTIME_STATE) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    return {"revoked": set(state.get("revoked", [])), "restored": set(state.get("restored", []))}


def revoked_ids():
    # Persistent list (ConfigMap, refreshed by the kubelet within ~a minute)
    # plus admin.py's immediate overrides.
    try:
        with open(REVOKED_FILE) as f:
            ids = {x.strip() for x in f.read().replace("\n", ",").split(",") if x.strip()}
    except OSError:
        ids = set()
    rt = runtime_state()
    return (ids | rt["revoked"]) - rt["restored"]


def _b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def parse_xfcc(header):
    # Envoy XFCC: key=value pairs separated by ';', values optionally quoted.
    # SanitizeSet yields exactly one element (this hop's client).
    fields = {}
    for m in re.finditer(r'(\w+)=("(?:[^"\\]|\\.)*"|[^;,]*)', header):
        k, v = m.group(1), m.group(2)
        fields.setdefault(k, unquote(v.strip('"')))
    return fields


def issue(client_id, client, scopes, cert_hash_hex=None):
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": client_id,
        "iat": now,
        "nbf": now,
        "exp": now + TOKEN_TTL,
        "jti": uuid.uuid4().hex,
        "scope": " ".join(sorted(scopes)),
        "client_kind": client.get("kind", "service"),
        "mediamtx_permissions": mediamtx_permissions(client_id, scopes),
    }
    if client.get("gpsi"):
        claims["gpsi"] = client["gpsi"]
    if cert_hash_hex:
        # RFC 8705 certificate-bound token: SHA-256 of the client cert (DER).
        claims["cnf"] = {"x5t#S256": _b64url(bytes.fromhex(cert_hash_hex))}
    with open(SIGNING_KEY) as f:
        key = f.read()
    with open(KID_FILE) as f:
        kid = f.read().strip()
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": kid})


def oauth_error(status, error, description):
    return JSONResponse({"error": error, "error_description": description}, status_code=status,
                        headers={"Cache-Control": "no-store"})


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/jwks.json")
def jwks():
    with open(JWKS_FILE) as f:
        return Response(f.read(), media_type="application/json")


@app.post("/token")
def token(
    request: Request,
    grant_type: str = Form(""),
    client_id: str = Form(""),
    client_secret: str = Form(""),
    scope: str = Form(""),
):
    if grant_type != "client_credentials":
        return oauth_error(400, "unsupported_grant_type", "only client_credentials is supported")

    # client_secret_basic: credentials in the Authorization header win.
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("basic "):
        try:
            client_id, _, client_secret = base64.b64decode(auth[6:]).decode().partition(":")
        except ValueError:
            return oauth_error(401, "invalid_client", "malformed basic credentials")

    policy = load_policy()
    client = policy.get(client_id)
    source = request.headers.get("x-forwarded-for", request.client.host if request.client else "?")
    if client is None:
        log.warning("token denied: unknown client %r from %s", client_id, source)
        return oauth_error(401, "invalid_client", "unknown client")

    cert_hash = None
    method = client.get("auth")
    if method == "tls_client_auth":
        xfcc = request.headers.get("x-forwarded-client-cert", "")
        fields = parse_xfcc(xfcc) if xfcc else {}
        cn = re.search(r"CN=([^,]+)", fields.get("Subject", ""))
        if not cn or cn.group(1) != client_id or not fields.get("Hash"):
            log.warning("token denied: %s from %s without a matching client certificate", client_id, source)
            return oauth_error(401, "invalid_client", "client certificate required and must match client_id")
        cert_hash = fields["Hash"]
    elif method == "client_secret_basic":
        try:
            with open(os.path.join(SECRETS_DIR, client_id)) as f:
                expected = f.read().strip()
        except OSError:
            expected = ""
        if not expected or not hmac.compare_digest(client_secret.encode(), expected.encode()):
            log.warning("token denied: bad secret for %s from %s", client_id, source)
            return oauth_error(401, "invalid_client", "invalid client credentials")
    else:
        return oauth_error(401, "invalid_client", "client has no usable authentication method")

    if client_id in revoked_ids() or not client.get("enabled", True):
        log.warning("token denied: %s is revoked (from %s)", client_id, source)
        return oauth_error(401, "invalid_client", "client is revoked")

    allowed = set(client.get("scopes", []))
    requested = set(scope.split()) if scope else allowed
    if not requested <= allowed:
        return oauth_error(400, "invalid_scope", f"allowed scopes: {' '.join(sorted(allowed))}")

    access_token = issue(client_id, client, requested, cert_hash)
    log.info("token issued: client=%s gpsi=%s scope=%s source=%s", client_id, client.get("gpsi", "-"),
             " ".join(sorted(requested)), source)
    return JSONResponse(
        {"access_token": access_token, "token_type": "Bearer", "expires_in": TOKEN_TTL,
         "scope": " ".join(sorted(requested))},
        headers={"Cache-Control": "no-store"},
    )
