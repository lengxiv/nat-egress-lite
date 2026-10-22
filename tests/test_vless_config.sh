#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/scripts/vless-config.sh"

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

# 仅用于测试的固定占位 X25519 格式值，绝非部署密钥。
readonly TEST_UUID='123e4567-e89b-42d3-a456-426614174000'
readonly TEST_PRIVATE='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
readonly TEST_PUBLIC='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
readonly TEST_SHORTID='0123456789abcdef'

set_valid_env() {
    export NE_VLESS_UUID=$TEST_UUID
    export NE_VLESS_LISTEN='0.0.0.0'
    export NE_VLESS_PORT='24443'
    export NE_PUBLIC_HOST='198.51.100.42'
    export NE_PUBLIC_PORT='443'
    export NE_REALITY_SNI='www.example.com'
    export NE_REALITY_PRIVATE=$TEST_PRIVATE
    export NE_REALITY_PUBLIC=$TEST_PUBLIC
    export NE_REALITY_SHORTID=$TEST_SHORTID
    export NE_VLESS_NAME='节点 测试 / α'
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

set_valid_env
vc_generate "$WORK/ipv4"

node_url=$(<"$WORK/ipv4/node.url")
expected_fragment='%E8%8A%82%E7%82%B9%20%E6%B5%8B%E8%AF%95%20%2F%20%CE%B1'
[[ $node_url == "vless://$TEST_UUID@198.51.100.42:443?"* ]] || fail 'URI 未使用 NE_PUBLIC_PORT'
[[ $node_url != *':24443?'* ]] || fail 'URI 误用了本机监听端口'
[[ $node_url == *"&spx=%2F#$expected_fragment" ]] || fail 'UTF-8 节点名称未按字节百分号编码'
[[ $(stat -c '%a' "$WORK/ipv4/config.json") == 600 ]] || fail 'config.json 权限不是 0600'
[[ $(stat -c '%a' "$WORK/ipv4/outbound.json") == 600 ]] || fail 'outbound.json 权限不是 0600'
[[ $(stat -c '%a' "$WORK/ipv4/node.url") == 600 ]] || fail 'node.url 权限不是 0600'

python3 - "$WORK/ipv4/config.json" "$WORK/ipv4/outbound.json" "$WORK/ipv4/node.url" "$TEST_PRIVATE" <<'PY'
import json
import pathlib
import sys

config = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
outbound = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
url = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
private = sys.argv[4]

inbound = config["inbounds"][0]
assert inbound["listen"] == "0.0.0.0"
assert inbound["port"] == 24443
assert inbound["protocol"] == "vless"
assert inbound["settings"]["decryption"] == "none"
assert inbound["settings"]["clients"][0]["flow"] == "xtls-rprx-vision"
reality = inbound["streamSettings"]["realitySettings"]
assert reality["target"] == "www.example.com:443"
assert reality["privateKey"] == private
assert config["log"] == {"loglevel": "error"}
assert config["routing"]["domainStrategy"] == "IPIfNonMatch"
private_rule = config["routing"]["rules"][0]
assert private_rule["outboundTag"] == "block-private"
assert "10.0.0.0/8" in private_rule["ip"] and "fc00::/7" in private_rule["ip"]
assert [item["protocol"] for item in config["outbounds"]] == ["freedom", "blackhole"]

client = outbound["outbounds"][0]
vnext = client["settings"]["vnext"][0]
assert vnext["address"] == "198.51.100.42"
assert vnext["port"] == 443
assert vnext["users"][0]["encryption"] == "none"
assert vnext["users"][0]["flow"] == "xtls-rprx-vision"
assert client["streamSettings"]["realitySettings"]["password"] != private
assert "privateKey" not in client["streamSettings"]["realitySettings"]
assert private not in json.dumps(outbound)
assert private not in url
PY

set_valid_env
export NE_PUBLIC_HOST='2001:db8:1::42'
export NE_PUBLIC_PORT='8443'
export NE_VLESS_NAME='IPv6 节点'
vc_generate "$WORK/ipv6"
ipv6_url=$(<"$WORK/ipv6/node.url")
[[ $ipv6_url == "vless://$TEST_UUID@[2001:db8:1::42]:8443?"* ]] || fail 'IPv6 URI 未使用方括号和公网映射端口'

must_reject() {
    local label=$1 variable=$2 value=$3
    if (
        set_valid_env
        printf -v "$variable" '%s' "$value"
        vc_generate "$WORK/reject-$label"
    ); then
        fail "非法输入被接受：$label"
    fi
}

must_reject uuid NE_VLESS_UUID 'not-a-uuid'
must_reject listen NE_VLESS_LISTEN '127.0.0.1'
must_reject local_port NE_VLESS_PORT '0'
must_reject public_host NE_PUBLIC_HOST '127.0.0.1'
must_reject public_port NE_PUBLIC_PORT '443;touch-bad'
must_reject sni NE_REALITY_SNI $'www.example.com\nmalicious'
must_reject private_key NE_REALITY_PRIVATE 'not-base64url'
must_reject short_id NE_REALITY_SHORTID 'abcdef'
must_reject name NE_VLESS_NAME $'first\nsecond'

printf 'PASS: VLESS/REALITY JSON、URI、IPv6、UTF-8 编码、私钥隔离和非法输入校验\n'
