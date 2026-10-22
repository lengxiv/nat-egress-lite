#!/usr/bin/env bash
# shellcheck shell=bash
# 通用 Linux 适配层；被 source 时不执行安装和服务操作。
NE_OS_ID=${NE_OS_ID-unknown}
NE_OS_VERSION=${NE_OS_VERSION-unknown}
NE_ARCH=${NE_ARCH-unknown}
NE_PACKAGE_MANAGER=${NE_PACKAGE_MANAGER-unknown}
NE_INIT=${NE_INIT-unsupported}
NE_SSH_BACKEND=${NE_SSH_BACKEND-}
NE_KEY_NAME=${NE_KEY_NAME-}
NE_APT_READY=${NE_APT_READY-0}
ne_log() { printf '%s\n' "$*" >&2; }
ne_die() { ne_log "错误：$*"; return 1; }

ne_detect_platform() {
    local key value machine
    NE_OS_ID=unknown; NE_OS_VERSION=unknown
    if [[ -r /etc/os-release ]]; then
        while IFS='=' read -r key value; do
            value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}
            case "$key" in ID) NE_OS_ID=$value;; VERSION_ID) NE_OS_VERSION=$value;; esac
        done < /etc/os-release
    fi
    machine=$(uname -m)
    case "$machine" in x86_64|amd64) NE_ARCH=amd64;; aarch64|arm64) NE_ARCH=arm64;; *) NE_ARCH=$machine;; esac
    if command -v apt-get >/dev/null 2>&1; then NE_PACKAGE_MANAGER=apt
    elif command -v apk >/dev/null 2>&1; then NE_PACKAGE_MANAGER=apk
    elif command -v dnf >/dev/null 2>&1; then NE_PACKAGE_MANAGER=dnf
    elif command -v yum >/dev/null 2>&1; then NE_PACKAGE_MANAGER=yum
    else NE_PACKAGE_MANAGER=unknown; fi
}
ne_detect_init() {
    NE_INIT=unsupported
    if [[ $(cat /proc/1/comm 2>/dev/null || true) == systemd ]] && command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
        NE_INIT=systemd
    elif command -v rc-service >/dev/null 2>&1 && { [[ -e /run/openrc/softlevel ]] || [[ $(cat /proc/1/comm 2>/dev/null || true) == init ]]; }; then
        NE_INIT=openrc
    fi
}
ne_package_install() {
    case "$NE_PACKAGE_MANAGER" in
        apt)
            if [[ $NE_APT_READY != 1 ]]; then apt-get update || return 1; NE_APT_READY=1; fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@";;
        apk) apk add --no-cache "$@";;
        dnf) dnf install -y "$@";;
        yum) yum install -y "$@";;
        *) ne_die '未发现受支持的包管理器';;
    esac
}
_ne_modern_dropbear() {
    local help
    command -v dbclient >/dev/null 2>&1 && command -v dropbearkey >/dev/null 2>&1 || return 1
    help=$(dbclient -o help 2>&1 || true)
    [[ $help == *BatchMode* && $help == *StrictHostKeyChecking* && $help == *ExitOnForwardFailure* ]]
}
_ne_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
    elif command -v busybox >/dev/null 2>&1; then busybox sha256sum "$1"
    else return 1; fi
}
ne_install_microsocks_fallback() {
    [[ $NE_ARCH == amd64 || $NE_ARCH == arm64 ]] || { ne_die "此架构 $NE_ARCH 需要发行版提供 microsocks；没有对应预编译组件。"; return 1; }
    local name="microsocks-linux-$NE_ARCH" url tmp expected actual
    url="https://github.com/lengxiv/nat-egress-lite/releases/download/v0.3.0/$name"
    [[ -r $NE_BUNDLE/microsocks.sha256 ]] || { ne_die '缺少 SHA256 清单，拒绝下载组件。'; return 1; }
    expected=$(awk -v f="$name" '$2 == f {print $1; exit}' "$NE_BUNDLE/microsocks.sha256")
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || { ne_die '组件校验值无效。'; return 1; }
    tmp=$(mktemp) || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    else rm -f "$tmp"; ne_die '没有 curl/wget，无法取得预编译组件。'; return 1; fi
    actual=$(_ne_sha256 "$tmp" | awk '{print $1}') || { rm -f "$tmp"; return 1; }
    [[ $actual == "$expected" ]] || { rm -f "$tmp"; ne_die 'SHA256 不匹配，拒绝安装。'; return 1; }
    install -d -m 0755 /usr/local/bin
    install -m 0755 "$tmp" /usr/local/bin/microsocks || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}
ne_install_dependencies() {
    ne_detect_platform
    local base=() ssh_needed=no
    if ! _ne_modern_dropbear && { ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; }; then ssh_needed=yes; fi
    case "$NE_PACKAGE_MANAGER" in
        apt)
            [[ $ssh_needed == no ]] || base+=(openssh-client)
            command -v ss >/dev/null 2>&1 || base+=(iproute2)
            command -v useradd >/dev/null 2>&1 || base+=(passwd)
            command -v su >/dev/null 2>&1 || base+=(util-linux);;
        apk)
            [[ $ssh_needed == no ]] || base+=(openssh-client-default)
            command -v ss >/dev/null 2>&1 || base+=(iproute2);;
        dnf|yum)
            [[ $ssh_needed == no ]] || base+=(openssh-clients)
            command -v ss >/dev/null 2>&1 || base+=(iproute)
            command -v useradd >/dev/null 2>&1 || base+=(shadow-utils);;
        *)
            if [[ $ssh_needed != no ]] || ! command -v ss >/dev/null 2>&1; then
                ne_die '此发行版需先手动准备 OpenSSH/密钥工具及 ss；不会猜测软件仓库。'
                return 1
            fi;;
    esac
    if ((${#base[@]})); then ne_package_install "${base[@]}" || return 1; fi
    # Dropbear 仅作为可选轻量优化；不能让它或 microsocks 的缺包拖垮基础依赖。
    if ! command -v dbclient >/dev/null 2>&1; then
        case "$NE_PACKAGE_MANAGER" in apt) ne_package_install dropbear-bin || true;; apk) ne_package_install dropbear || true;; esac
    fi
    if ! command -v microsocks >/dev/null 2>&1; then
        if [[ $NE_PACKAGE_MANAGER == unknown ]] || ! ne_package_install microsocks; then
            ne_log '未通过仓库获得 microsocks；使用带固定 SHA256 的预编译版本。'
        fi
        command -v microsocks >/dev/null 2>&1 || ne_install_microsocks_fallback || return 1
    fi
    command -v ss >/dev/null 2>&1 || { ne_die '安装后仍缺少 ss。'; return 1; }
    if ! _ne_modern_dropbear && { ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; }; then
        ne_die '没有可用的安全 SSH 客户端及密钥工具。'; return 1
    fi
    [[ $NE_PACKAGE_MANAGER != apt ]] || apt-get clean
}
ne_select_ssh() {
    if _ne_modern_dropbear; then NE_SSH_BACKEND=dropbear; NE_KEY_NAME=id_dropbear
    else NE_SSH_BACKEND=openssh; NE_KEY_NAME=id_ed25519; fi
    export NE_SSH_BACKEND NE_KEY_NAME
}
ne_run_as() {
    local user=$1 command='' argument escaped
    shift
    if command -v runuser >/dev/null 2>&1; then runuser -u "$user" -- "$@"
    elif command -v su >/dev/null 2>&1; then
        for argument in "$@"; do
            escaped=$(printf '%s' "$argument" | sed "s/'/'\\\\''/g")
            command+="'$escaped' "
        done
        su -s /bin/sh -c "exec $command" "$user"
    else ne_die '缺少 runuser/su。'; return 1; fi
}
ne_account_entry() {
    if command -v getent >/dev/null 2>&1; then getent "$1" "$2"
    else awk -F: -v name="$2" '$1 == name {print; found=1} END {if (!found) exit 2}' "/etc/$1"; fi
}
ne_create_account() {
    local user=${1:-nat-egress} group=${2:-nat-egress} home=${3:-/var/lib/nat-egress} nologin=/usr/sbin/nologin
    [[ -x $nologin ]] || nologin=/sbin/nologin
    [[ -x $nologin ]] || nologin=/bin/false
    if ! ne_account_entry group "$group" >/dev/null 2>&1; then
        if command -v groupadd >/dev/null 2>&1; then groupadd --system "$group"
        else addgroup -S "$group"; fi
    fi
    if ne_account_entry passwd "$user" >/dev/null 2>&1; then
        [[ $(ne_account_entry passwd "$user" | cut -d: -f6) == "$home" && $(id -gn "$user") == "$group" ]] || { ne_die '已有项目账户 HOME/主组不匹配，拒绝覆盖。'; return 1; }
    elif command -v useradd >/dev/null 2>&1; then
        useradd --system --gid "$group" --home-dir "$home" --create-home --shell "$nologin" "$user"
    else adduser -S -D -h "$home" -G "$group" -s "$nologin" "$user"; fi
    install -d -o "$user" -g "$group" -m 0700 "$home"
}
ne_service_active() {
    case "$NE_INIT" in systemd) systemctl is-active --quiet "$1";; openrc) rc-service "$1" status >/dev/null 2>&1;; *) return 1;; esac
}
ne_install_services() {
    local bundle=$1 name
    case "$NE_INIT" in
        systemd)
            install -m 0644 "$bundle/nat-egress-socks.service" "$bundle/nat-egress-tunnel.service" /etc/systemd/system/
            systemctl daemon-reload
            systemctl enable nat-egress-socks nat-egress-tunnel;;
        openrc)
            for name in socks tunnel; do
                install -m 0755 "$bundle/nat-egress-$name.openrc" "/etc/init.d/nat-egress-$name"
                rc-update add "nat-egress-$name" default
            done;;
        *) ne_die '需要实际运行的 systemd/OpenRC，不能注册常驻服务。'; return 1;;
    esac
}
ne_start_services() {
    case "$NE_INIT" in
        systemd) systemctl restart nat-egress-socks nat-egress-tunnel;;
        openrc)
            rc-service nat-egress-socks restart || rc-service nat-egress-socks start || return 1
            rc-service nat-egress-tunnel restart || rc-service nat-egress-tunnel start;;
        *) return 1;;
    esac
}
