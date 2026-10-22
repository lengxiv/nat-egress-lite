#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/scripts/setup-head.sh"
valid_port 22
valid_port 65535
valid_port 00108
if valid_port 0 || valid_port 65536 || valid_port '1;echo bad' || valid_port 123456789; then
    echo 'FAIL: invalid port accepted' >&2
    exit 1
fi
ss() {
    printf '%s\n' 'LISTEN 0 128 0.0.0.0:1080 0.0.0.0:*' 'LISTEN 0 128 [::]:22 [::]:*' 'LISTEN 0 128 127.0.0.1:19080 0.0.0.0:*'
}
port_busy 1080
port_busy 22
if port_busy 49152; then echo 'FAIL: free port detected busy'; exit 1; fi
chosen=$(free_local_port)
valid_port "$chosen"
[[ $chosen != 1080 ]]
if port_busy "$chosen"; then echo 'FAIL: occupied port selected'; exit 1; fi
echo 'PASS: port validation, IPv4/IPv6 listener parsing, occupied-port avoidance'
