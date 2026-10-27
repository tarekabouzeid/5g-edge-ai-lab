# Security — edge endpoint access control

## Why this exists

The `edge` DNN's whole point is that a phone's packets reach the edge site
directly, un-NAT'd (`docs/architecture.md`). The flip side: every device on
that DNN has a routed path to the minikube node and therefore to **every
NodePort on it**. Before this layer, anyone who could reach the node could:

- **publish video into the gateway** (mediamtx accepted anonymous
  publishers) — i.e. feed the AI a fake camera, or a stream of garbage;
- **read any stream** and use mediamtx's control API;
- call **edge-ingest's API** (NodePort 30080): pull live frames, and spend
  GPU time by asking the VLM arbitrary questions (`/api/ask`);
- and, from inside the cluster, call the **VLM** with no credentials.

Now every hop requires a key, and each caller holds only the keys it needs.

## What is enforced

| Endpoint | Reachable from | Who calls it | Credential | How it's presented |
|---|---|---|---|---|
| edge-gateway RTSP `:30554` (publish `/stream`) | NodePort — the UE's edge DNN, the host | the phone (UE) | **UE stream key** `EDGE_UE_STREAM_KEY` | `rtsp://ue:<key>@192.168.49.2:30554/stream` (RTSP Basic auth) |
| edge-gateway RTSP (read `/stream`) + API `:9997` | in-cluster | edge-ingest | gateway ingest key `EDGE_GATEWAY_INGEST_KEY` | user `ingest` (RTSP / HTTP Basic) |
| edge-ingest HTTP `:8080` / NodePort `30080` | NodePort — the UE, the host; in-cluster | lab portal, Prometheus, a browser on the demo page | ingest API key `EDGE_INGEST_API_KEY` | `X-API-Key: <key>`, `Authorization: Bearer <key>`, or `?key=<key>` (browser page only) |
| vlm `:8000` (llama-server) | in-cluster only (ClusterIP) | edge-ingest, Prometheus | VLM key `EDGE_VLM_API_KEY` | `Authorization: Bearer <key>` (llama-server `--api-key`) |

Deliberately public: edge-ingest `/healthz` (liveness/readiness and the
portal's round-trip probe, which runs from inside the UE) and its static `/`
page shell (it shows nothing without the key); the VLM's `/health`. Neither
returns data.

The phone's permission is narrow: user `ue` may **publish to `/stream`
only** — it can't read streams or use the API. edge-ingest's gateway login
may read `/stream` and query the API, but not publish.

## How the phone gets its key

In a real deployment the key would be provisioned into the device's app out
of band (app config, MDM, or better, a per-device credential — see
"Not covered yet"). In this lab the **lab portal plays the phone's camera
app**: it reads `EDGE_UE_STREAM_KEY` from `.env` and puts it in the RTSP URL
of the ffmpeg it starts inside the UE container. `scripts/demo-stream-from-ue.sh`
and `scripts/stream-test-video.sh` do the same. Central-cloud mode presents
the same key: the portal's relay forwards the bytes untouched.

## Where the keys live

```
.env (git-ignored, chmod 600)                 -- source of truth, generated
  └─ scripts/edge-keys.sh apply               -- run by ./lab.sh edge-apps up
       └─ Secret "edge-auth" (default ns)     -- ue-stream-key, ingest-api-key,
            ├─ edge-gateway  env MTX_AUTHINTERNALUSERS_{0,1}_PASS   gateway-ingest-key,
            ├─ edge-ingest   env GATEWAY_PASS, INGEST_API_KEY, VLM_API_KEY   vlm-api-key
            ├─ vlm           env LLAMA_API_KEY
            └─ prometheus    files /etc/edge-auth/{ingest,vlm}-api-key
  └─ lab portal (docker compose env)          -- EDGE_UE_STREAM_KEY, EDGE_INGEST_API_KEY
```

- **Generated, not chosen:** `./lab.sh edge-apps up` (and `portal up`) fill
  any empty key in `.env` with 48 random hex characters
  (`scripts/edge-keys.sh ensure`). Existing keys are kept.
- **Never in git or a manifest:** manifests only reference the Secret.
  mediamtx's ConfigMap lists the users with empty passwords; the passwords
  arrive through mediamtx's `MTX_AUTHINTERNALUSERS_<n>_PASS` environment
  overrides, which it applies after the config file.
- **Fail closed:** every `secretKeyRef` is mandatory, so a missing Secret
  keeps the pod from starting instead of starting it open. edge-ingest also
  refuses all non-public requests (503) if its key is somehow empty, and
  compares keys in constant time. Credentials are never logged (edge-ingest
  logs the RTSP URL without them).

## Rotating a key

```bash
sed -i 's/^EDGE_UE_STREAM_KEY=.*/EDGE_UE_STREAM_KEY=/' .env   # blank the one to rotate
./scripts/edge-keys.sh apply                                  # new value -> .env + Secret
kubectl rollout restart deployment/edge-gateway deployment/edge-ingest deployment/vlm
./lab.sh portal down && ./lab.sh portal up                    # portal re-reads .env
```

Pods read keys at start, so restart whatever consumes the rotated key
(table above). Prometheus re-reads its key files on every scrape.

## Check it works

```bash
set -a; source .env; set +a
N=$(minikube ip)
curl -s -o /dev/null -w '%{http_code}\n' http://$N:30080/api/state                                   # 401
curl -s -o /dev/null -w '%{http_code}\n' -H "X-API-Key: $EDGE_INGEST_API_KEY" http://$N:30080/api/state  # 200
curl -s -o /dev/null -w '%{http_code}\n' http://$N:30080/healthz                                     # 200 (public)
# From the phone, without the key — mediamtx rejects the publish:
docker exec ueransim-ue sh -c "timeout 5 ffmpeg -loglevel error -re -f lavfi -i testsrc -t 3 -c:v libx264 -f rtsp -rtsp_transport tcp rtsp://$N:30554/stream" ; echo "exit=$?"   # 401 Unauthorized
kubectl logs deploy/edge-gateway --tail=5    # the rejected attempt shows as an authentication error
```

The portal's camera should keep working throughout (it holds the key).

## Not covered yet (known gaps, roughly by priority)

- **No encryption on the edge hop.** RTSP Basic auth sends the key base64
  encoded, and the video in clear, between the UPF and the node (inside
  the GTP-U tunnel on the radio side, which is not encryption either).
  Next step: RTSPS (`encryption: strict` in mediamtx + a certificate) and
  HTTPS for edge-ingest.
- **One shared key for all phones.** Every UE uses the same stream key; a
  leaked key can't be revoked per device. Next step: per-device users, or
  mediamtx's JWT/HTTP auth backed by a token issuer that ties a token to the
  subscriber (SUPI); optionally also restrict the `ue` user's `ips` to the
  edge DNN's subnet (`10.47.0.0/16`) plus the relay's address.
- **The key is visible inside the UE container** (in ffmpeg's command line
  and, on errors, its log `/tmp/cam-ffmpeg.log`) — the same as any app
  holding a token on a device.
- **Kubernetes Secrets are only base64** in minikube's etcd (no encryption
  at rest), and anyone with `kubectl` access can read them.
- **No NetworkPolicy.** minikube's default CNI doesn't enforce it, so pods
  are not isolated from each other at the network level; the keys are the
  only barrier in-cluster.
- **Other surfaces in the lab, outside the edge endpoint:**
  - Open5GS WebUI is published on the host's port 9999 with the default
    login (`admin` / `1423`) — change it, or bind it to 127.0.0.1.
  - MongoDB (subscriber keys) has no authentication. It isn't published on
    the host, but it sits on the `open5gscore` network the UPF forwards UE
    traffic onto, so a phone can most likely reach it through its own data
    session (not verified) — the same goes for the NFs' SBI/metrics ports.
    Next step: MongoDB auth, and UPF-side filtering so UE traffic can't
    reach the core network.
  - Grafana's NodePort 30300 is reachable from the UE too; it's protected by
    `GRAFANA_ADMIN_PASSWORD` only.
  - The lab portal has no login; it binds to 127.0.0.1 because it holds the
    Docker socket.
  - The UE uses SUCI's null protection scheme (`ran/ue-config.yaml`), so its
    identity is sent unconcealed — a deliberate lab simplification.
