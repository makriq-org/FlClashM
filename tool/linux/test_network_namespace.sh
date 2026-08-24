#!/usr/bin/env bash
set -euo pipefail

helper=${1:?path to the built helper is required}
test_user=${2:?unprivileged CI user is required}
test_uid=$(id -u "$test_user")
test_gid=$(id -g "$test_user")

# The test is deliberately real: it creates a TUN interface and a route inside
# a fresh mount+network namespace, then proves rollback.  /run is a tmpfs, so
# the helper's durable transaction does not escape the namespace.
sudo unshare --mount --net --fork -- env \
  HELPER="$helper" CLIENT_UID="$test_uid" CLIENT_GID="$test_gid" \
  bash -ceu '
  mount --make-rprivate /
  mount -t tmpfs tmpfs /run
  mkdir -p /run/flclashm
  PKEXEC_UID="$CLIENT_UID" "$HELPER" --socket /run/flclashm/helper.sock &
  daemon=$!
  trap "kill $daemon 2>/dev/null || true" EXIT
  for _ in $(seq 1 30); do test -S /run/flclashm/helper.sock && break; sleep 0.1; done
  test -S /run/flclashm/helper.sock
  request() {
    printf "%s\\n" "$1" | setpriv --reuid="$CLIENT_UID" --regid="$CLIENT_GID" --clear-groups "$HELPER" --request
  }
  ready() { grep -q '"state":"ready"'; }
  request "{\"protocolVersion\":1,\"installIdentity\":\"app.flclashm.client\",\"operation\":\"tunOpen\",\"parameters\":{\"interface\":\"flclashm0\",\"mtu\":1500}}" | ready
  ip link show flclashm0 >/dev/null
  request "{\"protocolVersion\":1,\"installIdentity\":\"app.flclashm.client\",\"operation\":\"routeApply\",\"parameters\":{\"interface\":\"flclashm0\",\"routes\":[\"198.18.0.0/15\"]}}" | ready
  ip route show 198.18.0.0/15 | grep -q "flclashm0"
  request "{\"protocolVersion\":1,\"installIdentity\":\"app.flclashm.client\",\"operation\":\"routeRollback\",\"parameters\":{\"transaction\":\"ci_rollback\"}}" | ready
  ! ip link show flclashm0 >/dev/null 2>&1
  ! ip route show 198.18.0.0/15 | grep -q "flclashm0"
  before=$(sha256sum /etc/resolv.conf)
  request "{\"protocolVersion\":1,\"installIdentity\":\"app.flclashm.client\",\"operation\":\"dnsApply\",\"parameters\":{\"interface\":\"flclashm0\",\"servers\":[\"1.1.1.1\"]}}" | grep -q "\"state\":\"failed\""
  test "$before" = "$(sha256sum /etc/resolv.conf)"
'
