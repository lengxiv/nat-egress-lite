#!/usr/bin/env bash
# shellcheck shell=bash
# VLESS + TCP + REALITY 配置生成器；此文件只定义函数，供安装向导 source。

vc_log() {
    printf '%s\n' "$*" >&2
}

vc_die() {
    vc_log "错误：$*"
    return 1
}

vc_valid_port() {
    local value=$1
    [[ $value =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$value >= 1 && 10#$value <= 65535))
}

vc_valid_uuid() {
    [[ $1 =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]
}

# REALITY X25519 密钥是 32 字节、无 padding 的 base64url（43 字符）。
vc_valid_x25519_key() {
    [[ $1 =~ ^[A-Za-z0-9_-]{43}$ ]]
}

vc_valid_short_id() {
    [[ $1 =~ ^[0-9A-Fa-f]{16}$ ]]
}

vc_valid_domain() {
    local value=$1 label
    local -a labels=()
    [[ -n $value && ${#value} -le 253 && $value != *$'\n'* && $value != *$'\r'* && $value == *.* ]] || return 1
    IFS='.' read -r -a labels <<< "$value"
    ((${#labels[@]} >= 2)) || return 1
    for label in "${labels[@]}"; do
        [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
}

vc_valid_public_ipv4() {
    local value=$1 octet first second
    local -a octets=()
    [[ $value =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$value"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
    first=$((10#${octets[0]}))
    second=$((10#${octets[1]}))
    # 只排除明显不可作为公网节点地址的本地/私有/链路本地范围；不尝试探测可达性。
    case "$first.$second" in
        0.*|10.*|127.*|169.254|192.168) return 1;;
    esac
    ((first == 172 && second >= 16 && second <= 31)) && return 1
    ((first == 100 && second >= 64 && second <= 127)) && return 1
    ((first >= 224)) && return 1
    return 0
}

vc_valid_public_ipv6() {
    local value=$1 left right side group lower has_double=no count=0
    local -a groups=()
    [[ $value == *:* && $value =~ ^[0-9A-Fa-f:]+$ && $value != *:::* ]] || return 1
    if [[ $value == *::* ]]; then
        has_double=yes
        left=${value%%::*}
        right=${value#*::}
        [[ $right != *::* ]] || return 1
    else
        left=$value
        right=''
    fi
    for side in $left $right; do
        [[ -n $side ]] || continue
        IFS=':' read -r -a groups <<< "$side"
        for group in "${groups[@]}"; do
            [[ $group =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            ((count++))
        done
    done
    if [[ $has_double == yes ]]; then
        ((count < 8)) || return 1
    else
        ((count == 8)) || return 1
    fi
    lower=${value,,}
    [[ $lower != :: && $lower != ::1 && $lower != fc* && $lower != fd* && $lower != fe8* && $lower != fe9* && $lower != fea* && $lower != feb* && $lower != ff* ]]
}

vc_valid_public_host() {
    # 看起来像 IP 的输入不能在 IP 校验失败后回退为“数字域名”。
    if [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        vc_valid_public_ipv4 "$1"
    elif [[ $1 == *:* ]]; then
        vc_valid_public_ipv6 "$1"
    else
        vc_valid_domain "$1"
    fi
}

vc_urlencode() {
    # 在 C locale 下逐 UTF-8 字节编码；部署端不需要 Python。
    local input=$1 out='' char code index LC_ALL=C
    for ((index = 0; index < ${#input}; index++)); do
        char=${input:index:1}
        case "$char" in
            [A-Za-z0-9.~_-]) out+=$char;;
            *)
                printf -v code '%02X' "'$char"
                out+="%$code";;
        esac
    done
    printf '%s' "$out"
}

vc_generate() {
    if (($# != 1)); then
        vc_die '用法：vc_generate OUT_DIR'
        return 1
    fi

    local out_dir=$1 uuid=${NE_VLESS_UUID-} listen=${NE_VLESS_LISTEN-}
    local local_port=${NE_VLESS_PORT-} public_host=${NE_PUBLIC_HOST-} public_port=${NE_PUBLIC_PORT-}
    local sni=${NE_REALITY_SNI-} private_key=${NE_REALITY_PRIVATE-} public_key=${NE_REALITY_PUBLIC-}
    local short_id=${NE_REALITY_SHORTID-} name=${NE_VLESS_NAME-}
    local uri_host encoded_name tmp_config tmp_outbound tmp_url previous_umask

    vc_valid_uuid "$uuid" || { vc_die 'NE_VLESS_UUID 必须是标准 UUID。'; return 1; }
    [[ $listen == 0.0.0.0 || $listen == :: ]] || { vc_die 'NE_VLESS_LISTEN 只能是 0.0.0.0 或 ::。'; return 1; }
    vc_valid_port "$local_port" || { vc_die 'NE_VLESS_PORT 必须是 1..65535 的本机监听端口。'; return 1; }
    vc_valid_public_host "$public_host" || { vc_die 'NE_PUBLIC_HOST 必须是非本地的 IPv4、IPv6 或 ASCII 域名。'; return 1; }
    vc_valid_port "$public_port" || { vc_die 'NE_PUBLIC_PORT 必须是 1..65535 的公网映射端口。'; return 1; }
    vc_valid_domain "$sni" || { vc_die 'NE_REALITY_SNI 必须是 ASCII 域名。'; return 1; }
    vc_valid_x25519_key "$private_key" || { vc_die 'NE_REALITY_PRIVATE 必须是 43 字符 base64url X25519 私钥。'; return 1; }
    vc_valid_x25519_key "$public_key" || { vc_die 'NE_REALITY_PUBLIC 必须是 43 字符 base64url X25519 公钥。'; return 1; }
    vc_valid_short_id "$short_id" || { vc_die 'NE_REALITY_SHORTID 必须是 16 位十六进制。'; return 1; }
    [[ -n $name && ${#name} -le 256 && $name != *$'\n'* && $name != *$'\r'* ]] || {
        vc_die 'NE_VLESS_NAME 必须是最长 256 字节的非空单行名称。'
        return 1
    }

    if vc_valid_public_ipv6 "$public_host"; then uri_host="[$public_host]"; else uri_host=$public_host; fi
    encoded_name=$(vc_urlencode "$name") || { vc_die '节点名称编码失败。'; return 1; }

    previous_umask=$(umask)
    umask 077
    if [[ -e $out_dir && ! -d $out_dir ]]; then
        umask "$previous_umask"
        vc_die 'OUT_DIR 已存在但不是目录。'
        return 1
    fi
    mkdir -p -- "$out_dir" || {
        umask "$previous_umask"
        vc_die '无法创建 OUT_DIR。'
        return 1
    }
    chmod 0700 -- "$out_dir" || {
        umask "$previous_umask"
        vc_die '无法保护 OUT_DIR 权限。'
        return 1
    }
    tmp_config=$(mktemp "$out_dir/.config.json.XXXXXX") || { umask "$previous_umask"; vc_die '无法创建配置临时文件。'; return 1; }
    tmp_outbound=$(mktemp "$out_dir/.outbound.json.XXXXXX") || { rm -f -- "$tmp_config"; umask "$previous_umask"; vc_die '无法创建出站临时文件。'; return 1; }
    tmp_url=$(mktemp "$out_dir/.node.url.XXXXXX") || { rm -f -- "$tmp_config" "$tmp_outbound"; umask "$previous_umask"; vc_die '无法创建链接临时文件。'; return 1; }

    # 所有进入 JSON 的变量均经过严格 ASCII 格式验证；名称只写入 URI fragment。
    cat >"$tmp_config" <<EOF
{
  "log": {
    "loglevel": "error"
  },
  "inbounds": [
    {
      "tag": "nat-egress-vless-reality-in",
      "listen": "$listen",
      "port": $((10#$local_port)),
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$sni:443",
          "xver": 0,
          "serverNames": ["$sni"],
          "privateKey": "$private_key",
          "shortIds": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "block-private",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "224.0.0.0/4",
          "240.0.0.0/4",
          "::1/128",
          "fc00::/7",
          "fe80::/10",
          "ff00::/8"
        ],
        "outboundTag": "block-private"
      }
    ]
  }
}
EOF
    cat >"$tmp_outbound" <<EOF
{
  "outbounds": [
    {
      "tag": "nat-egress-vless-reality",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$public_host",
            "port": $((10#$public_port)),
            "users": [
              {
                "id": "$uuid",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "$sni",
          "password": "$public_key",
          "shortId": "$short_id",
          "spiderX": "/"
        }
      }
    }
  ]
}
EOF
    printf 'vless://%s@%s:%d?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision&spx=%%2F#%s\n' \
        "$uuid" "$uri_host" "$((10#$public_port))" "$sni" "$public_key" "$short_id" "$encoded_name" >"$tmp_url"

    chmod 0600 -- "$tmp_config" "$tmp_outbound" "$tmp_url" || {
        rm -f -- "$tmp_config" "$tmp_outbound" "$tmp_url"
        umask "$previous_umask"
        vc_die '无法保护生成文件权限。'
        return 1
    }
    if ! mv -f -- "$tmp_config" "$out_dir/config.json" || \
        ! mv -f -- "$tmp_outbound" "$out_dir/outbound.json" || \
        ! mv -f -- "$tmp_url" "$out_dir/node.url"; then
        rm -f -- "$tmp_config" "$tmp_outbound" "$tmp_url"
        umask "$previous_umask"
        vc_die '无法写入生成文件。'
        return 1
    fi
    chmod 0600 -- "$out_dir/config.json" "$out_dir/outbound.json" "$out_dir/node.url" || {
        umask "$previous_umask"
        vc_die '无法确认生成文件权限。'
        return 1
    }
    umask "$previous_umask"
}
