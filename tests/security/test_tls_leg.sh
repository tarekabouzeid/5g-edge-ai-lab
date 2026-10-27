#!/usr/bin/env bash
# The phone's mutual-TLS leg exactly as ran/edge-eec.sh opens it (socat),
# against a TLS server that requires client certs and checks the CRL; then
# revocation and restore with the real scripts/edge-pki.sh (kubectl stubbed).
# Usage: tests/security/test_tls_leg.sh <work dir from run.sh>
set -uo pipefail
W=$1; P=$W/.edge-pki; S=$W; FAIL=0
SRV=""; TUN=""
srv() { openssl s_server -accept 28322 -cert $P/server/edge.crt -key $P/server/edge.key -CAfile $P/ca/ca.crt -Verify 1 -verify_return_error -crl_check -CRL $P/ca/ca.crl -tls1_2 -rev -quiet >$S/srv.log 2>&1 & SRV=$!; sleep 0.7; }
tun() { socat TCP-LISTEN:18554,bind=127.0.0.1,reuseaddr,fork "OPENSSL:127.0.0.1:28322,$1" 2>$S/tun.log & TUN=$!; sleep 0.5; }
stop() { kill $TUN $SRV 2>/dev/null; wait $TUN $SRV 2>/dev/null; sleep 0.3; }
try() {  # try <label> <expect: ok|rejected>
  r=$(printf 'hello\n' | timeout 4 socat -t2 - TCP:127.0.0.1:18554 2>/dev/null | tr -d '\r')
  got=rejected; [ "$r" = olleh ] && got=ok
  if [ "$got" = "$2" ]; then echo "PASS tls: $1"; else echo "FAIL tls: $1 (got $got)"; FAIL=1; fi
  stop
}
ue() { echo "cert=$P/clients/$1.crt,key=$P/clients/$1.key,cafile=$P/ca/ca.crt,verify=1,commonname=$2,openssl-min-proto-version=TLS1.2"; }
srv; tun "$(ue eec-ue1 edge.lab)"; try "UE1 cert + edge.lab name" ok
srv; tun "$(ue eec-ue1 evil.lab)"; try "UE1 cert, wrong edge name" rejected
srv; tun "cafile=$P/ca/ca.crt,verify=1,commonname=edge.lab"; try "no client cert" rejected
srv; tun "$(ue eec-ue2 edge.lab)"; try "UE2 before revocation" ok
mkdir -p $S/kbin2 && printf '#!/bin/sh\ncase "$*" in *exec*) echo "   [kubectl stub] $*";; *get*) exit 1;; *"-f -"*) cat >/dev/null;; esac\n' > $S/kbin2/kubectl && chmod +x $S/kbin2/kubectl
(cd $W && PATH=$S/kbin2:$PATH ./scripts/edge-pki.sh revoke eec-ue2 >/dev/null)
srv; tun "$(ue eec-ue2 edge.lab)"; try "UE2 after revocation" rejected
srv; tun "$(ue eec-ue1 edge.lab)"; try "UE1 unaffected" ok
(cd $W && PATH=$S/kbin2:$PATH ./scripts/edge-pki.sh restore eec-ue2 >/dev/null 2>&1)
srv; tun "$(ue eec-ue2 edge.lab)"; try "UE2 restored (new cert)" ok
exit $FAIL
