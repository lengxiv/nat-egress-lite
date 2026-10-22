#!/usr/bin/env bash
# 此文件是独立 oneclick.sh 的源代码；发布文件由 build-oneclick.py 嵌入其依赖。
set -Eeuo pipefail

say() { printf '%s\n' "[一键部署] $*"; }
fail() { printf '%s\n' "[错误] $*" >&2; exit 1; }
ask_value() {
    local title=$1 default=$2 value
    if [[ -n $default ]]; then title="$title [$default]"; fi
    IFS= read -r -p "$title：" value </dev/tty || fail '交互输入中断。'
    REPLY=${value:-$default}
}
yes_no() {
    local title=$1 default=${2:-y}
    while true; do
        ask_value "$title（y/n）" "$default"
        case $REPLY in y|Y|yes|YES) return 0;; n|N|no|NO) return 1;; esac
        say '请输入 y 或 n。'
    done
}
valid_port() {
    [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}
listen_ports() {
    ss -H -ltn 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | sort -nu
}
port_busy() { listen_ports | grep -qx -- "$1"; }
free_local_port() {
    local candidate=1080 attempt
    if ! port_busy "$candidate"; then printf '%s\n' "$candidate"; return; fi
    for ((attempt=0; attempt<100; attempt++)); do
        candidate=$((20000 + RANDOM % 30000))
        if ! port_busy "$candidate"; then printf '%s\n' "$candidate"; return; fi
    done
    return 1
}
help_text() {
    cat <<'HELP'
NAT Egress Lite 交互式一键部署

在 Debian 13 NAT 落地机上以 root 运行：
  bash oneclick.sh
  或 sh install-debian.sh（已下载整个项目时）

输入日本 VPS 地址、可访问的 SSH 端口和管理员用户名即可开始。
落地 SOCKS 端口自动避开已监听端口，也可交互指定；日本反向端口自动选择。
脚本经 SSH 配置日本端并自动生成/校验/备份 Xray 配置，最后启动落地服务。
首次 SSH 连接需要你核对并确认主机指纹；密码在 SSH 提示中现场输入。
日本管理员须是 root，或具备免密 sudo；原生 Xray systemd 服务可自动合并。
不修改当前管理 SSH 端口，不会把 SOCKS 暴露公网。此方案仅支持 TCP。

--help       显示帮助
--dry-run    只说明将执行的操作，不安装、不连接、不修改服务
HELP
}

main() {
    case ${1:-} in --help|-h) help_text; return;; --dry-run) help_text; say '演练模式：没有安装软件、连接服务器或修改配置。'; return;; '') ;; *) fail '未知参数；运行 bash oneclick.sh --help。';; esac
    [[ $EUID -eq 0 ]] || fail '请以 root 运行。'
    [[ -r /dev/tty && -w /dev/tty ]] || fail '需要交互终端；请先保存脚本，再 bash oneclick.sh，不要直接把脚本 pipe 到 bash。'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ $ID == debian && $VERSION_ID == 13 ]] || fail '落地机安装器仅支持 Debian 13。'
    [[ $(cat /proc/1/comm) == systemd ]] || fail '此落地机的 PID 1 不是 systemd，不能自动注册服务。'
    : "${NE_BUNDLE:?请使用构建好的 oneclick.sh，而不是直接执行 setup-head.sh。}"
    umask 077
    say "目标系统：$PRETTY_NAME / $(dpkg --print-architecture)。不在落地机编译，不安装 Python 或 Docker。"
    say '目前只支持 TCP。监听端口检测不等于商家 NAT 映射或防火墙放行；落地端不需要公网入站映射。'
    free -m
    df -h /
    yes_no '开始安装并配置两端（日本端将备份并修改所选 Xray 配置）？' y || return 0

    local pkg missing=()
    for pkg in microsocks dropbear-bin iproute2; do
        if [[ $(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true) != installed ]]; then missing+=("$pkg"); fi
    done
    if ((${#missing[@]})); then
        say '安装缺失的 Debian 官方软件包；64 MB 容器的 apt 过程仍可能因资源不足失败。'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
        apt-get clean
    fi
    local dbhelp
    dbhelp=$(dbclient -o help 2>&1 || true)
    [[ $dbhelp == *StrictHostKeyChecking* && $dbhelp == *BatchMode* ]] || fail 'Dropbear 太旧或构建不完整；请更新 Debian 13 dropbear-bin 后重试。'
    ss -H -ltn >/dev/null 2>&1 || fail '无法读取本机监听端口；请检查容器对 ss/netlink 的限制。'

    local old_host='' old_jp_port=22 old_socks_port=''
    if [[ -f /etc/nat-egress/egress.conf && $(stat -c %u /etc/nat-egress/egress.conf) == 0 ]]; then
        # 只读取本项目管理员所有的可信 shell 配置。
        # shellcheck disable=SC1091
        source /etc/nat-egress/egress.conf
        old_host=${JP_HOST:-}; old_jp_port=${JP_PORT:-22}; old_socks_port=${SOCKS_PORT:-}
        [[ $old_host == REPLACE* ]] && old_host=''
    fi
    local jp_host jp_port admin_user admin_key socks_port remote_port configure_xray xray_config inbound_tag
    while true; do
        ask_value '日本 VPS 公网 IP 或域名' "$old_host"; jp_host=$REPLY
        [[ $jp_host =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] && break
        say '请填写单个 IP/域名，不带 URL、用户名、方括号或端口。'
    done
    say '日本 SSH 端口不能从落地机直接读取：使用你当前登录日本 VPS 的公网端口；它不是 Xray 的入口端口。'
    while true; do
        ask_value '日本 VPS 可访问的 SSH 端口' "$old_jp_port"
        if valid_port "$REPLY"; then jp_port=$((10#$REPLY)); break; fi
        say '端口应为 1 到 65535。'
    done
    while true; do
        ask_value '日本 VPS SSH 管理员（root 或具备免密 sudo 的用户）' root; admin_user=$REPLY
        [[ $admin_user =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] && break
    done
    ask_value '管理员 Dropbear 私钥路径（留空使用 SSH 密码/默认已有密钥）' ''; admin_key=$REPLY
    [[ -z $admin_key || -r $admin_key ]] || fail '管理员私钥文件不可读；私钥须为 Dropbear 原生格式。'
    say "本机已监听 TCP 端口：$(listen_ports | paste -sd, -)"
    local proposed
    if [[ -n $old_socks_port ]] && valid_port "$old_socks_port" && systemctl is-active --quiet nat-egress-socks; then
        proposed=$old_socks_port
    else
        proposed=$(free_local_port) || fail '未找到空闲本机端口，请检查监听情况。'
    fi
    while true; do
        ask_value '落地 SOCKS 端口（已自动避开占用，可直接回车）' "$proposed"
        if ! valid_port "$REPLY" || ((10#$REPLY < 1024)); then say '请填写 1024 到 65535。'; continue; fi
        socks_port=$((10#$REPLY))
        if port_busy "$socks_port"; then
            if [[ $socks_port == "$old_socks_port" ]] && systemctl is-active --quiet nat-egress-socks; then break; fi
            say "端口 $socks_port 已占用，请换一个；不会关闭其他进程。"
        else break; fi
    done
    while true; do
        ask_value '日本反向监听端口（0=在日本自动选空闲端口）' 0
        if [[ $REPLY == 0 ]]; then remote_port=0; break; fi
        if valid_port "$REPLY" && ((10#$REPLY >= 1024)); then remote_port=$((10#$REPLY)); break; fi
        say '输入 0 自动选择，或填写 1024 到 65535。'
    done
    if yes_no '自动对接日本的原生 Xray 服务？' y; then configure_xray=yes; else configure_xray=no; fi
    ask_value '日本 Xray 单文件 JSON 路径（回车自动识别）' auto; xray_config=$REPLY
    if [[ $configure_xray == yes ]]; then
        ask_value '要使用落地的 Xray 入站 tag（回车自动识别唯一入口）' auto
    else
        ask_value '要使用落地的 Xray 入站 tag（不自动修改 Xray 时必须填写）' ''
    fi
    inbound_tag=$REPLY
    [[ -n $inbound_tag ]] || fail '入站 tag 不能为空。'
    [[ $xray_config == auto || $xray_config == /* ]] || fail 'Xray 配置路径必须为绝对路径或 auto。'
    [[ $xray_config != *$'\n'* && $inbound_tag != *$'\n'* ]] || fail '路径/tag 不得含换行。'

    if ! id nat-egress >/dev/null 2>&1; then
        useradd --system --user-group --home-dir /var/lib/nat-egress --create-home --shell /usr/sbin/nologin nat-egress
    fi
    [[ $(getent passwd nat-egress | cut -d: -f6) == /var/lib/nat-egress ]] || fail '已有 nat-egress 账户家目录不匹配，拒绝覆盖。'
    install -d -o nat-egress -g nat-egress -m 0700 /var/lib/nat-egress /var/lib/nat-egress/.ssh
    if [[ ! -s /var/lib/nat-egress/.ssh/id_dropbear ]]; then
        runuser -u nat-egress -- dropbearkey -t ed25519 -f /var/lib/nat-egress/.ssh/id_dropbear >/dev/null
    fi
    local public_key socks_pass request response remote_command rc attempt actual_port host_key xray_status
    public_key=$(runuser -u nat-egress -- dropbearkey -y -f /var/lib/nat-egress/.ssh/id_dropbear | awk '/^ssh-ed25519 / {print $1 " " $2; exit}')
    [[ -n $public_key ]] || fail '无法提取落地公钥。'
    socks_pass=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
    request=$NE_BUNDLE/request.sh; response=$NE_BUNDLE/response.log
    remote_command='bash -s'
    [[ $admin_user == root ]] || remote_command='sudo -n bash -s'
    local ssh_args=(-T -K 20 -o StrictHostKeyChecking=ask -o BatchMode=no -p "$jp_port" -l "$admin_user")
    [[ -z $admin_key ]] || ssh_args+=(-i "$admin_key")
    say '连接日本 VPS；首次连接请通过可信控制台核对显示的主机指纹，再确认。SSH 密码直接在 SSH 提示中输入。'
    for ((attempt=1; attempt<=4; attempt++)); do
        {
            # 日本端执行时才展开这些变量，不在本机展开。
            # shellcheck disable=SC2016
            printf '#!/usr/bin/env bash\nset -Eeuo pipefail\numask 077\nNE_WORK_DIR=$(mktemp -d /tmp/ne-jp.XXXXXX)\nexport NE_WORK_DIR\ntrap '\''rm -rf -- "$NE_WORK_DIR"'\'' EXIT\n'
            printf "cat > \"\$NE_WORK_DIR/xray_merge.py\" <<'NE_MERGE_SCRIPT_9F17'\n"
            cat "$NE_BUNDLE/xray_merge.py"
            printf '\nNE_MERGE_SCRIPT_9F17\n'
            printf 'export NE_USER=%q NE_PUBLIC_KEY=%q NE_REMOTE_PORT=%q\n' nat-tunnel "$public_key" "$remote_port"
            printf 'export NE_SOCKS_USER=%q NE_SOCKS_PASS=%q\n' egress "$socks_pass"
            printf 'export NE_CONFIGURE_XRAY=%q NE_XRAY_CONFIG=%q NE_INBOUND_TAG=%q\n' "$configure_xray" "$xray_config" "$inbound_tag"
            cat "$NE_BUNDLE/setup-jp.sh"
        } > "$request"
        set +e
        dbclient "${ssh_args[@]}" "$jp_host" "$remote_command" < "$request" | tee "$response"
        rc=${PIPESTATUS[0]}
        set -e
        if ((rc==0)); then break; fi
        if ((rc==20 && attempt<4)); then
            if [[ -n $(sed -n 's/^NE_INBOUND_OPTIONS=//p' "$response" | tail -1) ]]; then
                say "检测到多个入口：$(sed -n 's/^NE_INBOUND_OPTIONS=//p' "$response")"
                ask_value '请选择一个实际入站 tag' ''; inbound_tag=$REPLY
                [[ -n $inbound_tag && $inbound_tag != *$'\n'* ]] || fail '入口 tag 无效。'
            elif grep -q '^NE_NEED_CONFIG=' "$response"; then
                say '自动识别存在歧义，请根据日本端输出填写明确的原生 Xray 配置路径。'
                ask_value '日本 Xray 配置绝对路径' ''; xray_config=$REPLY
                [[ $xray_config == /* && $xray_config != *$'\n'* ]] || fail '配置路径无效。'
            else fail '日本端要求额外配置，请检查上面的说明。'; fi
            continue
        fi
        fail '日本端未配置成功；本机未启用新服务。请处理 SSH/权限/Xray 错误后重新运行。'
    done
    actual_port=$(sed -n 's/^NE_REMOTE_PORT=//p' "$response" | tail -1)
    host_key=$(sed -n 's/^NE_HOST_KEY=//p' "$response" | tail -1)
    xray_status=$(sed -n 's/^NE_XRAY_STATUS=//p' "$response" | tail -1)
    valid_port "$actual_port" || fail '日本端没有返回有效反向端口。'
    [[ $host_key =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,3}$ ]] || fail '日本端没有返回有效的 Ed25519 主机公钥。'
    [[ $xray_status == merged || $xray_status == fragment ]] || fail '日本端 Xray 状态不完整。'

    install -d -o root -g nat-egress -m 0750 /etc/nat-egress
    if [[ -e /etc/nat-egress/egress.conf ]]; then cp -p /etc/nat-egress/egress.conf "/etc/nat-egress/egress.conf.backup.$(date +%s)"; fi
    {
        printf "JP_HOST='%s'\nJP_PORT='%s'\nJP_USER='nat-tunnel'\n" "$jp_host" "$jp_port"
        printf "REMOTE_PORT='%s'\nSOCKS_PORT='%s'\nSOCKS_USER='egress'\nSOCKS_PASS='%s'\nSSH_WINDOW='32768'\nSSH_KEEPALIVE='20'\n" "$actual_port" "$socks_port" "$socks_pass"
    } > /etc/nat-egress/egress.conf
    chown root:nat-egress /etc/nat-egress/egress.conf
    chmod 0640 /etc/nat-egress/egress.conf
    printf '%s %s\n' "$jp_host" "$host_key" > /var/lib/nat-egress/.ssh/known_hosts
    chown nat-egress:nat-egress /var/lib/nat-egress/.ssh/known_hosts
    chmod 0600 /var/lib/nat-egress/.ssh/known_hosts
    install -d -m 0755 /usr/local/lib/nat-egress
    install -m 0755 "$NE_BUNDLE/run-socks" "$NE_BUNDLE/run-tunnel" /usr/local/lib/nat-egress/
    install -m 0644 "$NE_BUNDLE/nat-egress-socks.service" "$NE_BUNDLE/nat-egress-tunnel.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable nat-egress-socks nat-egress-tunnel
    systemctl restart nat-egress-socks nat-egress-tunnel
    local ready=no
    for ((attempt=0; attempt<15; attempt++)); do
        if systemctl is-active --quiet nat-egress-socks && systemctl is-active --quiet nat-egress-tunnel; then ready=yes; break; fi
        sleep 1
    done
    [[ $ready == yes ]] || fail '本机服务启动失败，检查 systemctl status / journalctl；日本配置已完成。'
    say "本机服务已启动：落地 127.0.0.1:$socks_port，日本反向 127.0.0.1:$actual_port。"
    say '服务 active 不等于端到端健康；请在客户端验证实际出口，不能据此保证 64 MB 稳定或没有 DNS 泄漏。'
    if [[ $xray_status == merged ]]; then
        say '日本 Xray 已自动合并、校验并重载。现有客户端连接方式保持不变；选定入口的 TCP 走落地，UDP 阻断。'
    else
        say '你选择了不自动修改 Xray：日本端仅生成 /etc/nat-egress-jp/xray-fragment.json，尚未完成入口对接。'
    fi
    say '不需要打开落地 NAT 公网端口；没有修改日本管理 SSH 监听端口。'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
