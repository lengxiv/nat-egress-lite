#!/usr/bin/env bash
# 被独立 oneclick.sh 加载；默认部署真正的 VLESS REALITY 服务，而非 SSH/SOCKS 包装。
nv_help() {
    cat <<'HELP'
NAT Egress Lite — VLESS + REALITY 一键部署

默认：在落地机部署独立 VLESS 服务，自动生成 UUID、REALITY 密钥和 vless:// 链接。
填写本机监听端口、客户端能访问的公网地址与公网端口；NAT 必须已有 TCP 映射。
不需要入口 SSH 登录，不自动修改入口 Xray。链接用于客户端/面板导入，原生入口用 outbound.json。
无证书申请、不安装面板，不覆盖已有 Xray；服务名 nat-egress-vless。
自动识别 Linux 系统、架构以及 systemd/OpenRC。

bash oneclick.sh              交互部署 VLESS REALITY
bash oneclick.sh --show-link  显示本机已安装的节点链接（需要 root）
bash oneclick.sh --help       显示帮助
bash oneclick.sh --dry-run    只说明操作，不安装、不连接、不修改服务
bash oneclick.sh --ssh        使用旧版 SSH 反向隧道模式

VLESS 使用 Xray，内存占用高于 microsocks；24MiB 是 Go 软目标而不是整机占用。
64 MB 整机不能保证稳定。仅在允许入站 TCP 映射/公网访问的机器上直接分享节点。
HELP
}
nv_asset_name() {
    case "$1" in
        amd64|x86_64) printf '%s\n' Xray-linux-64.zip;;
        arm64|aarch64) printf '%s\n' Xray-linux-arm64-v8a.zip;;
        i386|i486|i586|i686|386) printf '%s\n' Xray-linux-32.zip;;
        armv7l|armv7|armv7a) printf '%s\n' Xray-linux-arm32-v7a.zip;;
        *) return 1;;
    esac
}
nv_dependencies() {
    local packages=()
    case "$NE_PACKAGE_MANAGER" in
        apt)
            command -v unzip >/dev/null 2>&1 || packages+=(unzip)
            command -v ss >/dev/null 2>&1 || packages+=(iproute2)
            command -v useradd >/dev/null 2>&1 || packages+=(passwd);;
        apk)
            command -v unzip >/dev/null 2>&1 || packages+=(unzip)
            command -v ss >/dev/null 2>&1 || packages+=(iproute2);;
        dnf|yum)
            command -v unzip >/dev/null 2>&1 || packages+=(unzip)
            command -v ss >/dev/null 2>&1 || packages+=(iproute)
            command -v useradd >/dev/null 2>&1 || packages+=(shadow-utils);;
    esac
    if ((${#packages[@]})); then ne_package_install "${packages[@]}" || return 1; fi
    command -v unzip >/dev/null 2>&1 && command -v ss >/dev/null 2>&1
}
nv_detect_public_ip() {
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O - https://api.ipify.org 2>/dev/null || true
    fi
}
nv_download_xray() {
    local asset expected actual archive=$NE_BUNDLE/xray.zip
    asset=$(nv_asset_name "$NE_ARCH") || { fail "架构 $NE_ARCH 暂没有内嵌的官方资产校验值。"; }
    expected=$(awk -v f="$asset" '$2 == f {print $1; exit}' "$NE_BUNDLE/xray.sha256")
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || fail '官方 Xray 摘要缺失，拒绝下载。'
    local url="https://github.com/XTLS/Xray-core/releases/download/v26.10.21/$asset"
    say "下载并校验官方 Xray：$NE_ARCH；只提取核心，不安装 GeoIP/GeoSite 数据库。"
    if command -v curl >/dev/null 2>&1; then curl -fsSL --proto '=https' "$url" -o "$archive"
    elif command -v wget >/dev/null 2>&1; then wget -O "$archive" "$url"
    else fail '需要 curl/wget。'; fi
    actual=$(_ne_sha256 "$archive" | awk '{print $1}')
    [[ $actual == "$expected" ]] || fail 'Xray SHA256 不匹配，拒绝运行。'
    mkdir -p "$NE_BUNDLE/xray-bin"
    unzip -jo "$archive" xray -d "$NE_BUNDLE/xray-bin" >/dev/null
    chmod 0755 "$NE_BUNDLE/xray-bin/xray"
    unzip -p "$archive" LICENSE > "$NE_BUNDLE/xray-bin/LICENSE" 2>/dev/null || rm -f "$NE_BUNDLE/xray-bin/LICENSE"
    rm -f "$archive"
}
nv_stop_service() {
    case "$NE_INIT" in systemd) systemctl stop nat-egress-vless;; openrc) rc-service nat-egress-vless stop;; esac
}
nv_start_service() {
    case "$NE_INIT" in systemd) systemctl start nat-egress-vless;; openrc) rc-service nat-egress-vless start;; esac
}
nv_main() {
    case ${1:-} in
        --help|-h) nv_help; return;;
        --dry-run) nv_help; say '演练：没有安装、连接或修改服务。'; return;;
        --show-link)
            [[ $EUID == 0 ]] || fail '请以 root 查看节点凭据。'
            [[ -s /etc/nat-egress-vless/node.url ]] || fail '尚未安装 VLESS 节点。'
            cat /etc/nat-egress-vless/node.url; return;;
        '') ;; *) fail '未知参数；运行 --help。';;
    esac
    [[ $EUID == 0 ]] || fail '请以 root 运行。'
    [[ $(uname -s) == Linux ]] || fail '仅支持 Linux。'
    [[ -r /dev/tty ]] || fail '需要交互终端；请下载后运行，不要直接 pipe 到 bash。'
    ne_detect_platform; ne_detect_init
    [[ $NE_INIT != unsupported ]] || fail '需要实际运行的 systemd/OpenRC；无 init 容器不能自动常驻部署。'
    say "通用 VLESS REALITY 落地：$NE_OS_ID $NE_OS_VERSION / $NE_ARCH / $NE_INIT"
    say 'NAT 公网映射无法从系统可靠识别：必须填写商家提供的可达地址和 TCP 端口。'
    say '64 MB 可能因 Xray/安装过程 OOM；软内存目标不是整机内存保证。'
    free -m; df -h /
    yes_no '部署 VLESS REALITY 独立服务（不改现有入口 Xray）？' y || return 0
    nv_dependencies || fail '缺少 unzip/ss 或依赖安装失败。'
    ss -H -ltn >/dev/null 2>&1 || fail '无法检测监听端口。'
    umask 077
    local old_port=8443 old_host='' old_public_port='' old_uuid='' old_private='' old_public='' old_sid='' old_sni=www.microsoft.com old_name=NAT-Egress
    if [[ -e /etc/nat-egress-vless/info.env ]]; then
        [[ -f /etc/nat-egress-vless/info.env && ! -L /etc/nat-egress-vless/info.env && $(stat -c %u /etc/nat-egress-vless/info.env) == 0 && $(stat -c %a /etc/nat-egress-vless/info.env) =~ ^(400|600)$ ]] || fail '已有凭据文件并非可信 root 私有文件，拒绝读取。'
        # 管理员所有的可信配置文件；只用于保留已生成节点身份。
        # shellcheck disable=SC1091
        source /etc/nat-egress-vless/info.env
        old_port=${NE_VLESS_PORT:-8443}; old_host=${NE_PUBLIC_HOST:-}; old_public_port=${NE_PUBLIC_PORT:-}
        old_uuid=${NE_VLESS_UUID:-}; old_private=${NE_REALITY_PRIVATE:-}; old_public=${NE_REALITY_PUBLIC:-}
        old_sid=${NE_REALITY_SHORTID:-}; old_sni=${NE_REALITY_SNI:-www.microsoft.com}; old_name=${NE_VLESS_NAME:-NAT-Egress}
    fi
    local proposed=$old_port attempts candidate
    if port_busy "$proposed" && ! ne_service_active nat-egress-vless; then
        for ((attempts=0; attempts<100; attempts++)); do
            candidate=$((20000 + RANDOM % 30000))
            if ! port_busy "$candidate"; then proposed=$candidate; break; fi
        done
    fi
    say "当前已监听 TCP 端口：$(listen_ports | paste -sd, -)"
    while true; do
        ask_value '落地本机监听端口（NAT 请填映射对应的内部端口，至少 1024）' "$proposed"
        if ! valid_port "$REPLY" || ((10#$REPLY < 1024)); then say '请输入 1024..65535。'; continue; fi
        NE_VLESS_PORT=$((10#$REPLY))
        if port_busy "$NE_VLESS_PORT" && ! { [[ $NE_VLESS_PORT == "$old_port" ]] && ne_service_active nat-egress-vless; }; then
            say '端口已被其他程序占用，不能覆盖。'; continue
        fi
        break
    done
    local detected=$old_host
    [[ -n $detected ]] || detected=$(nv_detect_public_ip)
    [[ $detected =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:-]*$ ]] || detected=''
    say '自动检测到的是出网地址，仅作建议；NAT 入站映射地址可能不同，请以商家面板为准。'
    while true; do
        ask_value '客户端可访问的公网 IP/域名' "$detected"; NE_PUBLIC_HOST=$REPLY
        vc_valid_public_host "$NE_PUBLIC_HOST" && break
        say '请输入非本地的公网 IP/完整域名，不带协议头、方括号、路径或端口。'
    done
    while true; do
        ask_value '公网访问端口（NAT 填外部映射端口；直连通常与监听端口相同）' "${old_public_port:-$NE_VLESS_PORT}"
        if valid_port "$REPLY"; then NE_PUBLIC_PORT=$((10#$REPLY)); break; fi
    done
    NE_VLESS_LISTEN=0.0.0.0
    [[ $NE_PUBLIC_HOST != *:* ]] || NE_VLESS_LISTEN='::'
    while true; do
        ask_value 'REALITY 目标域名/SNI（需要从落地访问其 TLS 服务）' "$old_sni"; NE_REALITY_SNI=$REPLY
        [[ $NE_REALITY_SNI =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]] && break
    done
    ask_value '节点名称' "$old_name"; NE_VLESS_NAME=$REPLY
    yes_no '确认该 TCP 端口已做公网映射/安全组放行（否则链接不可达）？' y || return 0

    NV_WAS_RUNNING=no; NV_COMPLETE=no
    NV_BACKUP=$NE_BUNDLE/old-config; NV_BINARY_BACKUP=$NE_BUNDLE/old-xray
    if ne_service_active nat-egress-vless; then
        say '检测到已有本项目 VLESS，将短暂停止它以降低升级内存峰值；节点身份会保留。'
        nv_stop_service; NV_WAS_RUNNING=yes
    fi
    # 无论安装过程何处失败，尽量恢复原服务；保留主构建器的临时目录清理。
    trap 'if [[ ${NV_COMPLETE:-no} != yes && ${NV_WAS_RUNNING:-no} == yes ]]; then nv_stop_service || true; if [[ -f $NV_BACKUP ]]; then cp -p "$NV_BACKUP" /etc/nat-egress-vless/config.json || true; fi; if [[ -f $NV_BINARY_BACKUP ]]; then cp -p "$NV_BINARY_BACKUP" /usr/local/lib/nat-egress-vless/xray || true; fi; nv_start_service || true; fi; rm -rf -- "$NE_BUNDLE"' EXIT
    nv_download_xray
    export GOMEMLIMIT=24MiB GOGC=50 GOMAXPROCS=1
    local core=$NE_BUNDLE/xray-bin/xray keys
    NE_VLESS_UUID=$old_uuid
    [[ -n $NE_VLESS_UUID ]] || NE_VLESS_UUID=$("$core" uuid)
    NE_REALITY_PRIVATE=$old_private; NE_REALITY_PUBLIC=$old_public
    if [[ -z $NE_REALITY_PRIVATE || -z $NE_REALITY_PUBLIC ]]; then
        keys=$("$core" x25519)
        NE_REALITY_PRIVATE=$(printf '%s\n' "$keys" | sed -nE 's/^Private(Key| key):[[:space:]]*//p')
        NE_REALITY_PUBLIC=$(printf '%s\n' "$keys" | sed -nE 's/^(Password.*|Public(Key| key)):[[:space:]]*//p')
    fi
    NE_REALITY_SHORTID=$old_sid
    [[ -n $NE_REALITY_SHORTID ]] || NE_REALITY_SHORTID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    export NE_VLESS_UUID NE_VLESS_LISTEN NE_VLESS_PORT NE_PUBLIC_HOST NE_PUBLIC_PORT NE_REALITY_SNI NE_REALITY_PRIVATE NE_REALITY_PUBLIC NE_REALITY_SHORTID NE_VLESS_NAME
    local stage=$NE_BUNDLE/vless-output
    vc_generate "$stage" || fail '无法生成合法的 VLESS 配置。'
    "$core" run -test -config "$stage/config.json" > "$NE_BUNDLE/vless-check.log" 2>&1 || { cat "$NE_BUNDLE/vless-check.log" >&2; fail '配置未通过 Xray 校验，未替换原服务。'; }
    ne_create_account nat-vless nat-vless /var/lib/nat-vless || fail '无法创建安全服务账户。'
    install -d -o root -g nat-vless -m 0750 /etc/nat-egress-vless
    install -d -o root -g root -m 0755 /usr/local/lib/nat-egress-vless
    local backup=$NE_BUNDLE/old-config binary_backup=$NE_BUNDLE/old-xray
    [[ ! -f /etc/nat-egress-vless/config.json ]] || cp -p /etc/nat-egress-vless/config.json "$backup"
    [[ ! -f /usr/local/lib/nat-egress-vless/xray ]] || cp -p /usr/local/lib/nat-egress-vless/xray "$binary_backup"
    install -m 0755 "$core" /usr/local/lib/nat-egress-vless/xray
    install -m 0755 "$NE_BUNDLE/run-vless" /usr/local/lib/nat-egress-vless/run-vless
    [[ ! -f $NE_BUNDLE/xray-bin/LICENSE ]] || install -m 0644 "$NE_BUNDLE/xray-bin/LICENSE" /usr/local/lib/nat-egress-vless/LICENSE
    install -o root -g nat-vless -m 0640 "$stage/config.json" /etc/nat-egress-vless/config.json
    if [[ $NE_INIT == systemd ]]; then
        install -m 0644 "$NE_BUNDLE/nat-egress-vless.service" /etc/systemd/system/
        systemctl daemon-reload; systemctl enable nat-egress-vless
    else
        install -m 0755 "$NE_BUNDLE/nat-egress-vless.openrc" /etc/init.d/nat-egress-vless
        rc-update add nat-egress-vless default
    fi
    local ready=no
    nv_start_service
    sleep 2
    for ((attempts=0; attempts<10; attempts++)); do
        if ne_service_active nat-egress-vless && port_busy "$NE_VLESS_PORT"; then ready=yes; break; fi
        sleep 1
    done
    if [[ $ready != yes ]]; then
        nv_stop_service || true
        [[ ! -f $backup ]] || cp -p "$backup" /etc/nat-egress-vless/config.json
        [[ ! -f $binary_backup ]] || cp -p "$binary_backup" /usr/local/lib/nat-egress-vless/xray
        fail 'VLESS 启动或监听失败；已尝试恢复旧配置，请检查内存、IPv6 和服务日志。'
    fi
    install -o root -g root -m 0600 "$stage/node.url" "$stage/outbound.json" /etc/nat-egress-vless/
    {
        local variable
        for variable in NE_VLESS_UUID NE_VLESS_LISTEN NE_VLESS_PORT NE_PUBLIC_HOST NE_PUBLIC_PORT NE_REALITY_SNI NE_REALITY_PRIVATE NE_REALITY_PUBLIC NE_REALITY_SHORTID NE_VLESS_NAME; do
            printf '%s=%q\n' "$variable" "${!variable}"
        done
    } > /etc/nat-egress-vless/info.env
    chmod 0600 /etc/nat-egress-vless/info.env
    NV_COMPLETE=yes
    say "VLESS REALITY 已监听：$NE_VLESS_LISTEN:$NE_VLESS_PORT；分享链接使用 $NE_PUBLIC_HOST:$NE_PUBLIC_PORT。"
    say '以下链接包含节点凭据，请勿公开。监听成功不代表公网映射/真实客户端已经验证。'
    cat /etc/nat-egress-vless/node.url
    say '链接已保存 /etc/nat-egress-vless/node.url；入口出站 JSON 在 /etc/nat-egress-vless/outbound.json。'
    say '此模式不需要入口 SSH 登录；把 vless:// 导入你的入口/客户端。64 MB 下请从低并发实测。'
}
