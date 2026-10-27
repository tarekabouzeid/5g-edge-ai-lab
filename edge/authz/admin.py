"""
Operator-side revocation, run inside the edge-authz pod (kubectl exec — no
network admin surface):

  python /app/admin.py revoke <client_id>    refuse tokens now + close its live streams
  python /app/admin.py restore <client_id>   lift the runtime revocation

The persistent record is the edge-authz-revoked ConfigMap (scripts/edge-pki.sh
updates both); this makes revocation take effect without waiting for the
ConfigMap volume to refresh.
"""
import json
import os
import sys

import requests

import app as authz

MEDIAMTX_API = os.environ.get("MEDIAMTX_API", "http://edge-gateway-api:9997")


def _write(state):
    os.makedirs(os.path.dirname(authz.RUNTIME_STATE), exist_ok=True)
    with open(authz.RUNTIME_STATE, "w") as f:
        json.dump({k: sorted(v) for k, v in state.items()}, f)


def kick_sessions(client_id):
    # A JWT is only checked when a stream starts, so close the ones open now.
    token = authz.issue("edge-authz", {"kind": "service"}, {"gateway.api"})
    headers = {"Authorization": f"Bearer {token}"}
    items = requests.get(f"{MEDIAMTX_API}/v3/rtspsessions/list", headers=headers, timeout=5).json().get("items", [])
    kicked = 0
    for s in items:
        if s.get("path") == f"ue/{client_id}":
            requests.post(f"{MEDIAMTX_API}/v3/rtspsessions/kick/{s['id']}", headers=headers, timeout=5).raise_for_status()
            kicked += 1
    return kicked


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("revoke", "restore"):
        sys.exit(__doc__)
    action, client_id = sys.argv[1], sys.argv[2]
    state = authz.runtime_state()
    if action == "revoke":
        state["revoked"].add(client_id)
        state["restored"].discard(client_id)
        _write(state)
        print(f"{client_id}: tokens refused; closed {kick_sessions(client_id)} live session(s)")
    else:
        state["revoked"].discard(client_id)
        state["restored"].add(client_id)
        _write(state)
        print(f"{client_id}: revocation lifted")


if __name__ == "__main__":
    main()
