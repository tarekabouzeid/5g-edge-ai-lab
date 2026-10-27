# Edge security — per-UE, per-endpoint, 3GPP-aligned

## What this answers

"How is each phone authenticated, and what can each one reach at the edge?"
Every phone has its **own identity** (a certificate from the operator CA,
carrying its EEC ID and GPSI), proves it with **mutual TLS**, and gets a
short-lived **OAuth 2.0 access token** that says exactly what it may do —
for a phone: publish video to *its own* stream path, nothing else. Every
endpoint checks the certificate, the token, or both. Any one phone can be
revoked live without touching the others.

This follows the model of **3GPP TS 33.558** (security for enabling edge
applications, TS 23.558 architecture): the edge client on the UE (EEC)
authenticates to the edge with certificates over TLS (profiled per
TS 33.210, i.e. TLS 1.2+), and is authorized with **OAuth 2.0 access
tokens** issued by the edge's authorization server (the ECS/EES role).
AKMA-based authentication — the option that derives app keys from the
5G primary authentication — isn't possible here: Open5GS has no AAnF.

## What is provisioned out of band

In a real deployment the operator/platform hands these to the device and
the edge; in the lab `scripts/edge-pki.sh` plays that role (everything in
`.edge-pki/`, git-ignored):

| Credential | Held by | Purpose |
|---|---|---|
| Operator CA (`ca.crt`) | every phone, Envoy, the portal | trust anchor for both sides |
| Edge server certificate (`edge.lab`, node IP, relay IP) | Envoy (Secret `edge-tls`) | the edge's TLS identity, verified by phones |
| Per-UE client certificate (CN = EEC ID, SAN URIs `urn:edge-lab:eec:<id>`, `urn:edge-lab:gpsi:<GPSI>`) | each phone at `/etc/edge/` | the phone's identity |
| Portal client certificate (`lab-portal`) | the lab portal | the operator console's identity |
| Token-signing key (RS256) / public JWKS | edge-authz / Envoy, mediamtx, edge-ingest | issue / verify access tokens |
| Service client secrets, VLM key (`.env`) | edge-ingest, Prometheus, VLM | in-cluster service credentials |

Phones get a **provisioning profile** (`/etc/edge/profile.env`): their
client ID, the token endpoint, the edge's RTSPS address and TLS name, and
their stream path.

## The flow (UE 1 starting its camera)

```
 UE 1 (EEC + camera app)          Envoy (edge front door)        edge-authz          mediamtx / edge-ingest
   |-- mTLS (UE 1 cert) --------->| verify cert vs CA + CRL       |                       |
   |   POST /token                |-- XFCC: cert hash+subject --->| client = CN?          |
   |   client_credentials         |                               | policy: scopes?       |
   |<----------- access token (JWT, sub=eec-ue1, scope=video.publish,                      |
   |             cnf=cert hash, mediamtx_permissions=[publish ue/eec-ue1], 10 min) --------|
   |-- mTLS tunnel (UE 1 cert) -->| RTSPS :30322, verify again      |                       |
   |   RTSP ANNOUNCE ue/eec-ue1   |-- plain RTSP + PROXY header (UE's 10.47.x.x) --------->| JWT valid?
   |   password = the JWT         |                                                        | path allowed?
   |========================== video ==========================================>        | -> YOLO + VLM
```

- **Step 1 — token (EEC ↔ authorization server).** OAuth 2.0 client
  credentials, client authentication by the TLS client certificate
  (RFC 8705 `tls_client_auth`). Envoy verifies the certificate against the
  operator CA and CRL and forwards it to edge-authz as an XFCC header
  (`SanitizeSet`: any client-supplied XFCC is dropped). edge-authz checks the
  certificate's CN equals the `client_id`, the client isn't revoked, and the
  requested scopes are within its policy (`edge/manifests/authz.yaml`).
- **The token** is an RS256 JWT: `iss`, `aud=edge-eas`, `sub`=EEC ID,
  `gpsi`, `scope`, 10-minute `exp`, **`cnf.x5t#S256`** (bound to that phone's
  certificate), and `mediamtx_permissions` (publish only to `ue/<EEC ID>`).
- **Step 2 — stream (AC ↔ EAS).** The EEC opens a mutual-TLS tunnel to
  Envoy's RTSPS listener (verifying the edge's certificate and name); the
  camera app (ffmpeg) streams RTSP through it with the token as its RTSP
  password. ffmpeg can't do client-certificate TLS itself, so the EEC owns
  TLS — the same split as the 3GPP EEC/AC model. Envoy terminates TLS and
  passes the phone's real address to mediamtx with the PROXY protocol;
  mediamtx verifies the JWT (signature, issuer, audience, expiry) and that
  the path is allowed.
- **Analytics.** edge-ingest (its own service token: read `ue/*`, gateway
  API) analyses the newest publisher; the portal reads results through
  Envoy with *its* certificate and token (scopes `ingest.read`, `ai.ask`).

## Endpoint matrix

| Endpoint | Reachable from | Authentication | Authorization |
|---|---|---|---|
| Envoy HTTPS `:30443` `/token` | phones (edge DNN), host | mTLS client cert (CA + CRL) | edge-authz policy, not revoked |
| Envoy HTTPS `:30443` `/api/state`, `/frame.jpg`, `/stream.mjpg`, `/status` | phones, host | mTLS + JWT (Envoy) | scope `ingest.read` (Envoy and edge-ingest); token bound to the presented cert (edge-ingest) |
| Envoy HTTPS `:30443` `/api/ask` | phones, host | mTLS + JWT | scope `ai.ask` |
| Envoy RTSPS `:30322` | phones (also via the central relay) | mTLS client cert (CA + CRL) + JWT (mediamtx) | `publish` only on `ue/<own EEC ID>` |
| Envoy HTTP `:30080` `/healthz` | anyone | — (no data) | public by design: liveness + the portal's RTT probe |
| edge-authz `:8080` | in-cluster only | client secret (service clients) | policy |
| mediamtx RTSP/API `:8554`/`:9997` | in-cluster only | JWT | `mediamtx_permissions` claim |
| edge-ingest `:8080` | in-cluster only | JWT (+ cert binding) | scopes, e.g. Prometheus `metrics.read` |
| vlm `:8000` | in-cluster only | static API key (llama-server limit) | — |

Nothing in the edge cluster is exposed on the node except Envoy.

## Threats and what stops them

| Threat | Stopped by |
|---|---|
| Unknown device streams fake video into the AI | no operator-issued certificate → TLS handshake fails at Envoy |
| UE 2 publishes onto UE 1's stream | token only allows `publish` on `ue/eec-ue2`; mediamtx refuses `ue/eec-ue1` |
| UE 2 asks for a token as UE 1 | edge-authz requires the certificate's CN to equal the `client_id` |
| A token is stolen (logs, a compromised app) | it expires in 10 min, and on HTTPS it only works together with the certificate it is bound to (`cnf`); on RTSPS the thief also needs that phone's key for the mTLS tunnel |
| A phone is lost or compromised | `edge-pki.sh revoke`: certificate on the CRL (no new TLS sessions), no new tokens, live streams closed — immediately |
| A phone reads other phones' video or uses the AI | phone tokens carry only `video.publish`; the APIs need `ingest.read` / `ai.ask` |
| Eavesdropping on the radio/backhaul hop | TLS 1.2+ end to end between the phone's EEC and Envoy |
| Forged, `alg=none`, expired, or wrong-audience tokens | rejected by Envoy, mediamtx and edge-ingest (all verify against the edge-authz JWKS) |
| A client sends its own XFCC header to impersonate | Envoy's `SanitizeSet` replaces it with the verified certificate |

## Operating it

```bash
./lab.sh all up                                # generates + loads everything, provisions both phones
./scripts/demo-stream-from-ue.sh demo-media/traffic.mp4 ueransim-ue2   # UE 2 streams too
./scripts/edge-pki.sh revoke eec-ue2           # UE 2 cut off live; UE 1 keeps streaming
./scripts/edge-pki.sh restore eec-ue2          # new certificate, provisioned to UE 2
```

- **Rotation:** delete `.edge-pki/` (or one client's files) and re-run
  `./lab.sh edge-apps up && ./lab.sh breakout up`. After rotating the
  token-signing key, restart `edge-gateway` (mediamtx fetches the JWKS once).
- **Adding a phone:** add it to `CLIENTS` in `scripts/edge-pki.sh` and to the
  policy in `edge/manifests/authz.yaml`, then the same two commands.
- **Audit:** `kubectl logs deploy/edge-authz` logs every issued or denied
  token with client, GPSI, scopes and source address.

## Check it works (DoD — run on the GPU host)

```bash
set -a; source .env; set +a; N=$(minikube ip); P=.edge-pki
curl -sk https://$N:30443/api/state -o /dev/null -w '%{http_code}\n'           # no client cert -> TLS error
curl -s --cacert $P/ca/ca.crt --cert $P/clients/lab-portal.crt --key $P/clients/lab-portal.key \
  https://$N:30443/api/state -o /dev/null -w '%{http_code}\n'                   # cert but no token -> 401
TOKEN=$(curl -s --cacert $P/ca/ca.crt --cert $P/clients/lab-portal.crt --key $P/clients/lab-portal.key \
  -d grant_type=client_credentials -d client_id=lab-portal https://$N:30443/token | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
curl -s --cacert $P/ca/ca.crt --cert $P/clients/lab-portal.crt --key $P/clients/lab-portal.key \
  -H "Authorization: Bearer $TOKEN" https://$N:30443/api/state -o /dev/null -w '%{http_code}\n'   # 200
curl -s -H "Authorization: Bearer $TOKEN" --cacert $P/ca/ca.crt --cert $P/clients/eec-ue1.crt --key $P/clients/eec-ue1.key \
  https://$N:30443/api/state -o /dev/null -w '%{http_code}\n'                   # portal token + UE 1's cert -> 401 (bound)
kubectl logs deploy/edge-authz --tail=5                                          # issued/denied tokens
kubectl logs deploy/edge-gateway --tail=5                                        # publishers as 10.47.x.x on ue/<id>
```

- [ ] both phones stream (portal for UE 1, `demo-stream-from-ue.sh … ueransim-ue2`); mediamtx shows `ue/eec-ue1` and `ue/eec-ue2` publishers from `10.47.x.x`
- [ ] the curl checks above return TLS error / 401 / 200 / 401
- [ ] `edge-pki.sh revoke eec-ue2` closes UE 2's stream within seconds; its EEC log then shows token refusals; UE 1 is unaffected
- [ ] `edge-pki.sh restore eec-ue2` lets UE 2 stream again
- [ ] Grafana's edge-ingest and VLM panels still have data (Prometheus' OAuth 2.0 client)

**Verified so far (in the build session, without a cluster):** edge-authz
(25 checks: cert-bound tokens, CN/client_id match, scopes, secrets,
revocation, JWKS), edge-ingest's token checks (21: stolen/forged/expired/
`alg=none`/wrong-audience/wrong-scope tokens rejected, cert binding), the
PKI and the phone's real TLS leg with socat 1.8 + OpenSSL 3 (handshake,
wrong edge name, missing client cert, CRL revocation and restore), and all
manifests against the Envoy Gateway v1.9.3 CRD schemas. **Not yet run
live:** Envoy Gateway on minikube and the full flow — the checklist above.

## Known risks / gaps

- **Trust inside the cluster.** edge-authz and edge-ingest trust the XFCC
  header because only Envoy should reach them; minikube's default CNI
  doesn't enforce NetworkPolicy, so another pod could forge it. Production:
  NetworkPolicy (or mTLS between Envoy and backends), and a CNI that
  enforces it.
- **Plain hops inside the cluster.** Envoy → mediamtx/edge-authz/edge-ingest
  and pod-to-pod traffic are unencrypted (service mesh / mTLS next).
- **mediamtx checks the token at connect time only**; that is why revocation
  also kicks live sessions (via its API) and tokens are short-lived.
- **Envoy Gateway + PROXY protocol on a TLS-terminated TCP listener** is
  configured per the v1.9.3 API but untested here (an older upstream issue,
  envoyproxy/gateway#3188, reported problems with this combination). If
  mediamtx then shows Envoy's pod IP instead of the phone's, remove the
  BackendTrafficPolicy — security is unaffected, only the address shown.
- **No AKMA / GBA**: certificate-based EEC authentication only (Open5GS
  has no AAnF). No binding of a token to the UE's PDU-session IP (would
  need a NEF query of SUPI ↔ IP).
- **Lab CA keys on disk** (`.edge-pki/`, mode 700); production uses an
  HSM-backed CA, short-lived certificates and OCSP.
- **Other surfaces, outside the edge endpoint:** Open5GS WebUI on host
  port 9999 with the default login (`admin` / `1423`); MongoDB without auth
  (reachable from UEs through the UPF, most likely); Grafana NodePort 30300
  (password only); the portal has no login (127.0.0.1 only, holds the
  Docker socket); SUCI null scheme (`ran/ue-config.yaml`).
