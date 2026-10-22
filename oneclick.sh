#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
NE_BUNDLE=$(mktemp -d /tmp/ne-install.XXXXXX)
trap 'rm -rf -- "$NE_BUNDLE"' EXIT
cat > "$NE_BUNDLE/run-socks" <<'NE_EMBED_730A0ACFB8A5C4B3'
#!/bin/sh
set -eu
CONF=${1:-/etc/nat-egress/egress.conf}
[ -r "$CONF" ] || { echo '无法读取落地配置。' >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
case ${SOCKS_PORT:-} in ''|*[!0-9]*) echo 'SOCKS_PORT 必须为整数。' >&2; exit 1;; esac
[ "$SOCKS_PORT" -ge 1024 ] && [ "$SOCKS_PORT" -le 65535 ] || exit 1
[ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ] || exit 1
[ "$SOCKS_PASS" != REPLACE_WITH_RANDOM_PASSWORD ] || { echo '请先设置 SOCKS 密码。' >&2; exit 1; }
# 单个进程的 FD 上限，控制极小内存机器的并发资源；不等于精确连接数。
# Debian /bin/sh 是 dash，支持此扩展。
# shellcheck disable=SC3045
ulimit -n 64
exec microsocks -i 127.0.0.1 -p "$SOCKS_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS"
NE_EMBED_730A0ACFB8A5C4B3
cat > "$NE_BUNDLE/run-tunnel" <<'NE_EMBED_4526190AFD2B34E8'
#!/bin/sh
set -eu
CONF=${1:-/etc/nat-egress/egress.conf}
[ -r "$CONF" ] || { echo '无法读取落地配置。' >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
case ${JP_HOST:-} in ''|REPLACE*|-*|*[!a-zA-Z0-9.:-]*) echo '入口地址请填写单个 IP 或域名。' >&2; exit 1;; esac
case ${JP_USER:-} in ''|*[!a-zA-Z0-9_-]*) echo '隧道用户名无效。' >&2; exit 1;; esac
for value in "${JP_PORT:-}" "${REMOTE_PORT:-}" "${SOCKS_PORT:-}"; do
    case "$value" in ''|*[!0-9]*) echo '端口必须为整数。' >&2; exit 1;; esac
    [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || exit 1
done
case ${SSH_WINDOW:-} in ''|*[!0-9]*) exit 1;; esac
[ "$SSH_WINDOW" -ge 16384 ] && [ "$SSH_WINDOW" -le 131072 ] || exit 1
case ${SSH_KEEPALIVE:-} in ''|*[!0-9]*) exit 1;; esac
[ "$SSH_KEEPALIVE" -ge 10 ] && [ "$SSH_KEEPALIVE" -le 60 ] || exit 1
case ${SSH_BACKEND:-dropbear} in
    dropbear) key="$HOME/.ssh/id_dropbear";;
    openssh) key="$HOME/.ssh/id_ed25519";;
    *) echo 'SSH 后端必须是 dropbear 或 openssh。' >&2; exit 1;;
esac
if [ ! -s "$key" ] || [ ! -s "$HOME/.ssh/known_hosts" ]; then
    echo '缺少对应后端的私钥或经过核验的入口主机公钥。' >&2
    exit 1
fi
unset DROPBEAR_PASSWORD SSH_AUTH_SOCK SSH_ASKPASS SSH_ASKPASS_ALWAYS
# dash、BusyBox ash 均支持此文件描述符限制。
# shellcheck disable=SC3045
ulimit -n 64
if [ "${SSH_BACKEND:-dropbear}" = openssh ]; then
    exec ssh -F /dev/null -N -T -o BatchMode=yes -o PasswordAuthentication=no \
        -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes \
        -o "UserKnownHostsFile=$HOME/.ssh/known_hosts" -o GlobalKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -o Compression=no -o ConnectTimeout=20 \
        -o "ServerAliveInterval=$SSH_KEEPALIVE" -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes -p "$JP_PORT" -l "$JP_USER" -i "$key" \
        -R "127.0.0.1:$REMOTE_PORT:127.0.0.1:$SOCKS_PORT" "$JP_HOST"
fi
exec dbclient -N -T -K "$SSH_KEEPALIVE" -W "$SSH_WINDOW" \
    -o BatchMode=yes -o PasswordAuthentication=no \
    -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes \
    -p "$JP_PORT" -l "$JP_USER" -i "$key" \
    -R "127.0.0.1:$REMOTE_PORT:127.0.0.1:$SOCKS_PORT" "$JP_HOST"
NE_EMBED_4526190AFD2B34E8
cat > "$NE_BUNDLE/nat-egress-socks.service" <<'NE_EMBED_EDF8C6A213450C21'
[Unit]
Description=NAT Egress Lite - loopback SOCKS5 TCP
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=nat-egress
Group=nat-egress
Environment=HOME=/var/lib/nat-egress
ExecStart=/usr/local/lib/nat-egress/run-socks
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077
LimitNOFILE=64
TasksMax=40
MemoryAccounting=true
MemoryMax=16M
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
NE_EMBED_EDF8C6A213450C21
cat > "$NE_BUNDLE/nat-egress-tunnel.service" <<'NE_EMBED_3A833C36A1BD6CC9'
[Unit]
Description=NAT Egress Lite - authenticated reverse SSH tunnel
Wants=network-online.target nat-egress-socks.service
After=network-online.target nat-egress-socks.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=nat-egress
Group=nat-egress
Environment=HOME=/var/lib/nat-egress
ExecStart=/usr/local/lib/nat-egress/run-tunnel
Restart=always
RestartSec=10
TimeoutStopSec=10
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077
LimitNOFILE=64
TasksMax=8
MemoryAccounting=true
MemoryMax=20M
LogRateLimitIntervalSec=60s
LogRateLimitBurst=5
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
NE_EMBED_3A833C36A1BD6CC9
cat > "$NE_BUNDLE/setup-jp.sh" <<'NE_EMBED_A9A006BF0483700B'
#!/usr/bin/env bash
# Configure only the nat-egress SSH account and (optionally) one root Xray JSON.
# This helper is intentionally run on the Japanese VPS as root, not on the NAT
# machine.  It never opens a firewall port and never changes global SSH options.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly TUNNEL_USER='nat-tunnel'
readonly TUNNEL_HOME='/var/lib/nat-tunnel'
readonly SSHD_CONFIG='/etc/ssh/sshd_config'
readonly SSHD_DROPIN_DIR='/etc/ssh/sshd_config.d'
readonly SSHD_DROPIN="${SSHD_DROPIN_DIR}/60-nat-egress.conf"
readonly STATE_DIR='/etc/nat-egress-jp'
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly PASS_FILE="${STATE_DIR}/socks-pass"
readonly FRAGMENT_FILE="${STATE_DIR}/xray-fragment.json"
readonly MANAGED_MARKER='# Managed by nat-egress-jp; do not edit manually'

CANDIDATE=''
FRAGMENT_CANDIDATE=''
AUTH_TMP=''
DROPIN_TMP=''
STATE_TMP=''
PASS_TMP=''
AUTH_BACKUP=''
DROPIN_BACKUP=''
AUTH_FILE="${TUNNEL_HOME}/.ssh/authorized_keys"
ACCOUNT_CREATED=0
SSH_DIR_CREATED=0
AUTH_EXISTED=0
DROPIN_EXISTED=0
SSH_CHANGED=0
SSH_SERVICE=''

log_info() { printf '信息：%s\n' "$*"; }
log_error() { printf '错误：%s\n' "$*" >&2; }
die() { log_error "$*"; exit 1; }

cleanup_temps() {
    local path
    for path in "$CANDIDATE" "$FRAGMENT_CANDIDATE" "$AUTH_TMP" "$DROPIN_TMP" \
        "$STATE_TMP" "$PASS_TMP" "$AUTH_BACKUP" "$DROPIN_BACKUP"; do
        if [[ -n "$path" && -e "$path" ]]; then
            rm -f -- "$path" || true
        fi
    done
}
trap cleanup_temps EXIT

need_config() {
    # stdout is reserved for the parent one-click script's machine-readable
    # selection prompt.  It contains no password or other secret.
    printf 'NE_NEED_CONFIG=%s\n' "$1"
    printf 'NE_INBOUND_OPTIONS=%s\n' "${2:-}"
    exit 20
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        die "缺少必需环境变量 ${name}"
    fi
}

state_value() {
    local key="$1" line
    [[ -f "$STATE_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "${key}="* ]]; then
            printf '%s' "${line#*=}"
            return 0
        fi
    done < "$STATE_FILE"
}

check_state_permissions() {
    local owner mode
    [[ -f "$STATE_FILE" ]] || return 0
    owner=$(stat -c '%u' -- "$STATE_FILE") || die '无法检查已有 state.env 权限'
    mode=$(stat -c '%a' -- "$STATE_FILE") || die '无法检查已有 state.env 权限'
    [[ "$owner" == '0' && ( "$mode" == '600' || "$mode" == '400' ) ]] || die '已有 state.env 权限不安全，拒绝读取'
}

port_is_listening() {
    local port="$1"
    grep -Fxq -- "$port" <<< "$LISTENING_PORTS"
}

random_free_high_port() {
    local candidate entropy attempt
    for ((attempt = 0; attempt < 200; attempt++)); do
        entropy=$(od -An -N2 -tu2 /dev/urandom | tr -d '[:space:]') || return 1
        candidate=$((49152 + (10#${entropy} % 16384)))
        if ! port_is_listening "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

add_config_candidate() {
    local candidate="$1" known
    [[ "$candidate" == /* && -f "$candidate" ]] || return 0
    for known in "${XRAY_CANDIDATES[@]}"; do
        [[ "$known" == "$candidate" ]] && return 0
    done
    XRAY_CANDIDATES+=("$candidate")
}

discover_xray_config() {
    local exec_start extracted
    XRAY_CANDIDATES=()
    exec_start=$(systemctl show xray.service -p ExecStart --value 2>/dev/null || true)
    # systemctl's rendered ExecStart has an argv[] section.  Extract only the
    # conventional -config/-c argument form, then confirm the path exists.
    while IFS= read -r extracted; do
        extracted=$(sed -E 's/^-config(=|[[:space:]]+)//; s/^-c(=|[[:space:]]+)//' <<< "$extracted")
        add_config_candidate "$extracted"
    done < <(printf '%s\n' "$exec_start" | grep -oE -- '(-config|-c)(=|[[:space:]])[^[:space:];}]+' || true)
    add_config_candidate '/usr/local/etc/xray/config.json'
    add_config_candidate '/etc/xray/config.json'

    if ((${#XRAY_CANDIDATES[@]} == 0)); then
        need_config '未发现原生 Xray 根配置；请设置绝对路径 NE_XRAY_CONFIG'
    fi
    if ((${#XRAY_CANDIDATES[@]} > 1)); then
        need_config "发现多个 Xray 根配置候选：$(IFS=,; printf '%s' "${XRAY_CANDIDATES[*]}")"
    fi
    XRAY_CONFIG="${XRAY_CANDIDATES[0]}"
}

run_merger_inspect() {
    local output rc
    set +e
    output=$(python3 "$MERGER" --inspect "$XRAY_CONFIG" 2>&1)
    rc=$?
    set -e
    if ((rc == 20)); then
        printf '%s\n' "$output"
        exit 20
    fi
    if ((rc != 0)); then
        log_error 'Xray 配置预检失败；未改动 SSH 或 Xray 服务'
        [[ -n "$output" ]] && printf '错误：%s\n' "$output" >&2
        exit 1
    fi
}

build_xray_candidate() {
    local mode output rc
    mode=$(stat -c '%a' -- "$XRAY_CONFIG") || die '无法读取 Xray 配置文件权限'
    CANDIDATE=$(mktemp "$(dirname -- "$XRAY_CONFIG")/.nat-egress-jp.XXXXXX") || die '无法在 Xray 配置目录创建候选文件'
    chmod "$mode" -- "$CANDIDATE" || die '无法设置 Xray 候选文件权限'
    chown --reference="$XRAY_CONFIG" -- "$CANDIDATE" || die '无法设置 Xray 候选文件属主'

    set +e
    output=$(python3 "$MERGER" "$XRAY_CONFIG" "$CANDIDATE" 2>&1)
    rc=$?
    set -e
    if ((rc == 20)); then
        printf '%s\n' "$output"
        exit 20
    fi
    if ((rc != 0)); then
        log_error '无法生成 Xray 候选配置；未改动任何服务'
        [[ -n "$output" ]] && printf '错误：%s\n' "$output" >&2
        exit 1
    fi
    if ! "$XRAY_BIN" run -test -config "$CANDIDATE" >/dev/null 2>&1; then
        die 'Xray 候选配置未通过 run -test；未改动 SSH 或 Xray 服务'
    fi
}

build_fragment_candidate() {
    local output rc
    FRAGMENT_CANDIDATE=$(mktemp "${NE_WORK_DIR}/.nat-egress-fragment.XXXXXX") || die '无法创建 Xray 片段临时文件'
    set +e
    output=$(python3 "$MERGER" --fragment "$FRAGMENT_CANDIDATE" 2>&1)
    rc=$?
    set -e
    if ((rc == 20)); then
        printf '%s\n' "$output"
        exit 20
    fi
    if ((rc != 0)); then
        log_error '无法生成 Xray root 合并片段；未改动 SSH 服务'
        [[ -n "$output" ]] && printf '错误：%s\n' "$output" >&2
        exit 1
    fi
    chmod 600 -- "$FRAGMENT_CANDIDATE" || die '无法保护 Xray 片段文件'
}

prepare_ssh_backups() {
    if [[ -e "$AUTH_FILE" ]]; then
        [[ ! -L "$AUTH_FILE" && -f "$AUTH_FILE" ]] || die 'authorized_keys 不是普通文件，拒绝覆盖'
        AUTH_EXISTED=1
        AUTH_BACKUP=$(mktemp "${NE_WORK_DIR}/.nat-egress-auth.XXXXXX") || die '无法备份 authorized_keys'
        cp -a -- "$AUTH_FILE" "$AUTH_BACKUP" || die '无法备份 authorized_keys'
    fi
    if [[ -e "$SSHD_DROPIN" ]]; then
        [[ ! -L "$SSHD_DROPIN" && -f "$SSHD_DROPIN" ]] || die '已有 SSH drop-in 不是普通文件，拒绝覆盖'
        grep -Fxq -- "$MANAGED_MARKER" "$SSHD_DROPIN" || die '已有 SSH drop-in 非本项目管理，拒绝覆盖'
        ((STATE_MANAGED == 1)) || die '已有 SSH drop-in 但无受管 state.env，拒绝覆盖'
        DROPIN_EXISTED=1
        DROPIN_BACKUP=$(mktemp "${NE_WORK_DIR}/.nat-egress-dropin.XXXXXX") || die '无法备份 SSH drop-in'
        cp -a -- "$SSHD_DROPIN" "$DROPIN_BACKUP" || die '无法备份 SSH drop-in'
    fi
}

rollback_ssh() {
    # Do not restart SSH here: reloading a known-valid restored configuration
    # preserves the existing management daemon and its listening port.
    ((SSH_CHANGED == 1)) || return 0
    log_info '正在回滚本次 SSH 专用账户与 drop-in 改动'
    if ((DROPIN_EXISTED == 1)); then
        cp -a -- "$DROPIN_BACKUP" "$SSHD_DROPIN" || log_error '无法恢复原 SSH drop-in'
    else
        rm -f -- "$SSHD_DROPIN" || log_error '无法删除新 SSH drop-in'
    fi
    if ((ACCOUNT_CREATED == 1)); then
        userdel --remove "$TUNNEL_USER" >/dev/null 2>&1 || log_error '无法删除本次新建的 nat-tunnel 账户'
    else
        if ((AUTH_EXISTED == 1)); then
            cp -a -- "$AUTH_BACKUP" "$AUTH_FILE" || log_error '无法恢复原 authorized_keys'
        else
            rm -f -- "$AUTH_FILE" || log_error '无法删除本次新 authorized_keys'
        fi
        if ((SSH_DIR_CREATED == 1)); then
            rmdir "${TUNNEL_HOME}/.ssh" >/dev/null 2>&1 || true
        fi
    fi
    if "$SSHD_BIN" -t -f "$SSHD_CONFIG" >/dev/null 2>&1; then
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            systemctl reload "$SSH_SERVICE" >/dev/null 2>&1 || log_error '恢复 SSH 配置后 reload 失败；未执行 restart'
        else
            log_error 'SSH 服务已不在 active 状态，回滚后未盲目 restart'
        fi
    else
        log_error '恢复后的 SSH 配置未通过 sshd -t，未执行 reload'
    fi
    SSH_CHANGED=0
}

apply_ssh_changes() {
    local account_line account_home account_shell account_password effective
    if account_line=$(getent passwd "$TUNNEL_USER"); then
        if ((STATE_MANAGED != 1)); then
            log_error '已有 nat-tunnel 账户但无本项目受管 state.env，拒绝覆盖'
            return 1
        fi
        IFS=: read -r _ _ _ _ _ account_home account_shell <<< "$account_line"
        if [[ "$account_home" != "$TUNNEL_HOME" || "$account_shell" != '/usr/sbin/nologin' ]]; then
            log_error '已有受管 nat-tunnel 账户属性不符合预期，拒绝覆盖'
            return 1
        fi
        account_password=$(getent shadow "$TUNNEL_USER" | awk -F: '{print $2}')
        if [[ "$account_password" != '*' ]]; then
            log_error '已有受管 nat-tunnel 账户密码字段不是 *，拒绝覆盖'
            return 1
        fi
    else
        if ! useradd --system --user-group --create-home --home-dir "$TUNNEL_HOME" \
            --shell /usr/sbin/nologin --password '*' "$TUNNEL_USER"; then
            log_error '无法创建 nat-tunnel 专用账户'
            return 1
        fi
        ACCOUNT_CREATED=1
        SSH_CHANGED=1
    fi

    if [[ ! -d "${TUNNEL_HOME}/.ssh" ]]; then
        if ! install -d -o "$TUNNEL_USER" -g "$TUNNEL_USER" -m 0700 "${TUNNEL_HOME}/.ssh"; then
            log_error '无法创建 nat-tunnel .ssh 目录'
            return 1
        fi
        SSH_DIR_CREATED=1
        SSH_CHANGED=1
    fi
    if ! install -d -o "$TUNNEL_USER" -g "$TUNNEL_USER" -m 0700 "$TUNNEL_HOME"; then
        log_error '无法设置 nat-tunnel 家目录权限'
        return 1
    fi

    AUTH_TMP=$(mktemp "${NE_WORK_DIR}/.nat-egress-authorized.XXXXXX") || return 1
    printf 'restrict,port-forwarding,permitlisten="127.0.0.1:%s" %s nat-egress\n' \
        "$REMOTE_PORT" "$NE_PUBLIC_KEY" > "$AUTH_TMP" || return 1
    if ! chown "$TUNNEL_USER:$TUNNEL_USER" "$AUTH_TMP" || ! chmod 0600 "$AUTH_TMP" || ! mv -f -- "$AUTH_TMP" "$AUTH_FILE"; then
        log_error '无法安全写入 nat-tunnel authorized_keys'
        return 1
    fi
    AUTH_TMP=''
    SSH_CHANGED=1

    DROPIN_TMP=$(mktemp "${NE_WORK_DIR}/.nat-egress-sshd.XXXXXX") || return 1
    cat > "$DROPIN_TMP" <<EOF
${MANAGED_MARKER}
# Only the dedicated reverse-forward account is matched; global SSH policy and listeners stay untouched.
Match User ${TUNNEL_USER}
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding remote
    PermitListen 127.0.0.1:${REMOTE_PORT}
    PermitOpen none
    GatewayPorts no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
    MaxSessions 0
    ClientAliveInterval 20
    ClientAliveCountMax 3
Match all
EOF
    if ! chown root:root "$DROPIN_TMP" || ! chmod 0600 "$DROPIN_TMP" || ! mv -f -- "$DROPIN_TMP" "$SSHD_DROPIN"; then
        log_error '无法安全写入 SSH Match drop-in'
        return 1
    fi
    DROPIN_TMP=''
    SSH_CHANGED=1

    if ! "$SSHD_BIN" -t -f "$SSHD_CONFIG" >/dev/null 2>&1; then
        log_error 'sshd -t 未通过'
        return 1
    fi
    if ! effective=$("$SSHD_BIN" -T -f "$SSHD_CONFIG" -C 'user=nat-tunnel,host=nat-egress,addr=127.0.0.1' 2>/dev/null); then
        log_error 'sshd -T effective 检查失败'
        return 1
    fi
    if ! grep -Fxq 'allowtcpforwarding remote' <<< "$effective" || \
        ! grep -Fxq "permitlisten 127.0.0.1:${REMOTE_PORT}" <<< "$effective" || \
        ! grep -Fxq 'gatewayports no' <<< "$effective" || \
        ! grep -Fxq 'maxsessions 0' <<< "$effective" || \
        ! grep -Fxq 'passwordauthentication no' <<< "$effective"; then
        log_error 'sshd -T 生效值未满足 remote/PermitListen/GatewayPorts/MaxSessions 限制'
        return 1
    fi
    if ! systemctl reload "$SSH_SERVICE" >/dev/null 2>&1; then
        log_error 'SSH reload 失败'
        return 1
    fi
    if ! systemctl is-active --quiet "$SSH_SERVICE"; then
        log_error 'SSH reload 后服务非 active；不会盲目 restart'
        return 1
    fi
    return 0
}

install_xray_candidate() {
    local backup_dir backup mode restore
    mode=$(stat -c '%a' -- "$XRAY_CONFIG") || return 1
    backup_dir="${STATE_DIR}/backups"
    install -d -o root -g root -m 0700 "$backup_dir" || return 1
    backup="${backup_dir}/$(basename -- "$XRAY_CONFIG").$(date -u +%Y%m%dT%H%M%SZ).$$.bak"
    install -o root -g root -m 0600 "$XRAY_CONFIG" "$backup" || return 1
    if ! mv -f -- "$CANDIDATE" "$XRAY_CONFIG"; then
        log_error '无法原子替换 Xray 配置'
        return 1
    fi
    CANDIDATE=''
    if systemctl restart xray >/dev/null 2>&1 && systemctl is-active --quiet xray; then
        XRAY_STATUS='merged'
        return 0
    fi

    log_error 'Xray restart 失败；正在恢复备份配置并重启旧配置'
    restore=$(mktemp "$(dirname -- "$XRAY_CONFIG")/.nat-egress-restore.XXXXXX") || return 1
    cp -- "$backup" "$restore" || { rm -f -- "$restore"; return 1; }
    chmod "$mode" -- "$restore" || { rm -f -- "$restore"; return 1; }
    chown --reference="$XRAY_CONFIG" -- "$restore" || { rm -f -- "$restore"; return 1; }
    mv -f -- "$restore" "$XRAY_CONFIG" || return 1
    if ! systemctl restart xray >/dev/null 2>&1; then
        log_error '旧 Xray 配置已恢复到磁盘，但重新启动仍失败；请在现有管理会话诊断'
    fi
    return 1
}

install_fragment() {
    install -d -o root -g root -m 0700 "$STATE_DIR" || return 1
    install -o root -g root -m 0600 "$FRAGMENT_CANDIDATE" "$FRAGMENT_FILE" || return 1
    XRAY_STATUS='fragment'
    return 0
}

write_state() {
    install -d -o root -g root -m 0700 "$STATE_DIR" || return 1
    PASS_TMP=$(mktemp "${STATE_DIR}/.socks-pass.XXXXXX") || return 1
    printf '%s\n' "$NE_SOCKS_PASS" > "$PASS_TMP" || return 1
    chown root:root "$PASS_TMP" || return 1
    chmod 0600 "$PASS_TMP" || return 1
    mv -f -- "$PASS_TMP" "$PASS_FILE" || return 1
    PASS_TMP=''

    STATE_TMP=$(mktemp "${STATE_DIR}/.state.XXXXXX") || return 1
    cat > "$STATE_TMP" <<EOF
# Managed by nat-egress-jp. Values are data, never shell-sourced.
NE_MANAGED=1
NE_PUBLIC_KEY=${NE_PUBLIC_KEY}
NE_REMOTE_PORT=${REMOTE_PORT}
NE_INBOUND_TAG=${NE_INBOUND_TAG}
NE_XRAY_CONFIG=${STATE_XRAY_CONFIG}
NE_CONFIGURE_XRAY=${NE_CONFIGURE_XRAY}
EOF
    chown root:root "$STATE_TMP" || return 1
    chmod 0600 "$STATE_TMP" || return 1
    mv -f -- "$STATE_TMP" "$STATE_FILE" || return 1
    STATE_TMP=''
}

# ----- immutable preflight: no account, sshd, or Xray service is changed -----
[[ $(id -u) -eq 0 ]] || die '必须以 root（或 sudo -n bash -s）执行'
for variable in NE_WORK_DIR NE_PUBLIC_KEY NE_REMOTE_PORT NE_SOCKS_USER NE_SOCKS_PASS \
    NE_XRAY_CONFIG NE_INBOUND_TAG NE_CONFIGURE_XRAY; do
    require_env "$variable"
done

[[ -d "$NE_WORK_DIR" && -w "$NE_WORK_DIR" ]] || die 'NE_WORK_DIR 必须是可写临时目录'
MERGER="${NE_WORK_DIR}/xray_merge.py"
[[ -f "$MERGER" && ! -L "$MERGER" && -r "$MERGER" ]] || die 'NE_WORK_DIR 中缺少可读取的 xray_merge.py'
[[ "$NE_PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/]+={0,3}$ ]] || die 'NE_PUBLIC_KEY 必须仅为 ssh-ed25519 Base64 公钥'
PUBLIC_KEY_DATA=${NE_PUBLIC_KEY#ssh-ed25519 }
printf '%s' "$PUBLIC_KEY_DATA" | base64 --decode >/dev/null 2>&1 || die 'NE_PUBLIC_KEY 的 Base64 数据无效'
[[ "$NE_REMOTE_PORT" == '0' || "$NE_REMOTE_PORT" =~ ^[0-9]+$ ]] || die 'NE_REMOTE_PORT 必须为 0 或数字'
if [[ "$NE_REMOTE_PORT" != '0' ]] && ((NE_REMOTE_PORT < 1024 || NE_REMOTE_PORT > 65535)); then
    die 'NE_REMOTE_PORT 显式值必须在 1024..65535'
fi
[[ "$NE_SOCKS_USER" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die 'NE_SOCKS_USER 包含不允许的字符'
[[ "$NE_SOCKS_PASS" =~ ^[0-9A-Fa-f]{48}$ ]] || die 'NE_SOCKS_PASS 必须是随机 48 位十六进制串'
[[ "$NE_XRAY_CONFIG" == 'auto' || "$NE_XRAY_CONFIG" == /* ]] || die 'NE_XRAY_CONFIG 必须是 auto 或绝对路径'
[[ "$NE_INBOUND_TAG" == 'auto' || "$NE_INBOUND_TAG" =~ ^[A-Za-z0-9._:@+-]+(,[A-Za-z0-9._:@+-]+)*$ ]] || die 'NE_INBOUND_TAG 格式不安全'
[[ "$NE_CONFIGURE_XRAY" == 'yes' || "$NE_CONFIGURE_XRAY" == 'no' ]] || die 'NE_CONFIGURE_XRAY 必须为 yes 或 no'

SSHD_BIN=$(command -v sshd || true)
[[ -n "$SSHD_BIN" && -x "$SSHD_BIN" ]] || die '未发现可用 sshd；不会安装、重启或改动现有 SSH'
[[ -r "$SSHD_CONFIG" && -d "$SSHD_DROPIN_DIR" ]] || die '缺少 sshd 主配置或 drop-in 目录'
grep -Eq '^[[:space:]]*Include[[:space:]]+.*(/etc/ssh/sshd_config\.d/\*\.conf|/etc/ssh/sshd_config\.d/)' "$SSHD_CONFIG" || \
    die 'sshd 主配置未 Include /etc/ssh/sshd_config.d；拒绝改动 SSH'
for service in ssh sshd; do
    if systemctl is-active --quiet "$service"; then
        SSH_SERVICE="$service"
        break
    fi
done
[[ -n "$SSH_SERVICE" ]] || die '现有 SSH systemd 服务未处于 active；不会安装或盲目 restart'

HOST_KEY_FILE=''
EFFECTIVE_HOST_KEYS=$("$SSHD_BIN" -T -f "$SSHD_CONFIG" 2>/dev/null | awk '$1 == "hostkey" {print $2}') || die '无法读取 sshd 实际启用的主机密钥'
while IFS= read -r configured_host_key; do
    [[ -r "${configured_host_key}.pub" ]] || continue
    IFS=' ' read -r configured_host_algo _ < "${configured_host_key}.pub"
    if [[ "$configured_host_algo" == 'ssh-ed25519' ]]; then
        HOST_KEY_FILE="${configured_host_key}.pub"
        break
    fi
done <<< "$EFFECTIVE_HOST_KEYS"
[[ -n "$HOST_KEY_FILE" ]] || die '未发现 sshd 实际启用的 Ed25519 主机公钥；不会生成或替换管理主机密钥'
IFS=' ' read -r HOST_KEY_ALGO HOST_KEY_DATA _ < "$HOST_KEY_FILE"
[[ "$HOST_KEY_ALGO" == 'ssh-ed25519' && "$HOST_KEY_DATA" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || \
    die 'SSH Ed25519 主机公钥格式无效；不会生成新主机密钥'
ssh-keygen -lf "$HOST_KEY_FILE" >/dev/null 2>&1 || die 'SSH Ed25519 主机公钥未通过有效性核验；不会生成新主机密钥'
HOST_KEY="${HOST_KEY_ALGO} ${HOST_KEY_DATA}"

check_state_permissions
STATE_MANAGED=0
PREVIOUS_KEY=''
PREVIOUS_PORT=''
if [[ -f "$STATE_FILE" ]]; then
    [[ $(state_value 'NE_MANAGED') == '1' ]] || die '已有 state.env 非本项目受管格式，拒绝覆盖'
    PREVIOUS_KEY=$(state_value 'NE_PUBLIC_KEY')
    [[ "$PREVIOUS_KEY" == "$NE_PUBLIC_KEY" ]] || die '已有受管 state.env 的公钥不同，拒绝覆盖 nat-tunnel'
    PREVIOUS_PORT=$(state_value 'NE_REMOTE_PORT')
    if ! [[ "$PREVIOUS_PORT" =~ ^[0-9]+$ ]] || ((PREVIOUS_PORT < 1024 || PREVIOUS_PORT > 65535)); then
        die '已有 state.env 的反向端口无效，拒绝覆盖'
    fi
    STATE_MANAGED=1
fi

LISTENING_PORTS=$(ss -H -ltn | awk '{address=$4; sub(/^.*:/, "", address); if (address ~ /^[0-9]+$/) print address}') || \
    die '无法用 ss -H -ltn 检查本机 TCP 监听'
if [[ "$NE_REMOTE_PORT" == '0' ]]; then
    if ((STATE_MANAGED == 1)); then
        REMOTE_PORT="$PREVIOUS_PORT"
        log_info '复用已有受管反向端口；即使当前隧道正在回环监听也不会误判为冲突'
    elif ! port_is_listening 19080; then
        REMOTE_PORT=19080
    else
        REMOTE_PORT=$(random_free_high_port) || die '无法选择空闲随机高端口'
    fi
else
    REMOTE_PORT="$NE_REMOTE_PORT"
    if port_is_listening "$REMOTE_PORT" && ! { ((STATE_MANAGED == 1)) && [[ "$REMOTE_PORT" == "$PREVIOUS_PORT" ]]; }; then
        die "请求的反向端口 ${REMOTE_PORT} 已被 IPv4 或 IPv6 TCP 监听占用"
    fi
fi
# JSON 合并器必须得到已选择的实际端口，而不是父脚本传入的自动选择占位值 0。
export NE_REMOTE_PORT="$REMOTE_PORT"

# Reject an account that may belong to someone else before any config candidate,
# package operation, or service reload.  A missing account with no state is the
# only unmanaged state this helper is allowed to create.
if getent passwd "$TUNNEL_USER" >/dev/null 2>&1 && ((STATE_MANAGED != 1)); then
    die '已有未管理的 nat-tunnel 账户；拒绝覆盖'
fi
prepare_ssh_backups

if ! command -v python3 >/dev/null 2>&1; then
    log_info '未发现 python3；仅在日本 VPS 安装 python3 用于安全解析 Xray JSON'
    command -v apt-get >/dev/null 2>&1 || die '缺少 python3 且无 apt-get，无法解析 Xray JSON'
    if ! apt-get update >/dev/null 2>&1 || ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 >/dev/null 2>&1; then
        die '安装 python3 失败；未改动 SSH 或 Xray 服务'
    fi
fi

XRAY_STATUS=''
XRAY_CONFIG=''
XRAY_BIN=''
STATE_XRAY_CONFIG='fragment'
if [[ "$NE_CONFIGURE_XRAY" == 'yes' ]]; then
    XRAY_EXEC_START=$(systemctl show xray.service -p ExecStart --value 2>/dev/null || true)
    if [[ "$XRAY_EXEC_START" =~ (docker|podman|x-ui|3x-ui|marzban) ]]; then
        need_config '检测到 Docker 或面板管理的 Xray；请人工选择根配置，不自动修改'
    fi
    XRAY_BIN=$(command -v xray || true)
    [[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]] || die '未发现 xray 命令；拒绝自动修改配置'
    [[ $(systemctl show xray.service -p LoadState --value 2>/dev/null || true) != 'not-found' ]] || \
        die '未发现原生 xray.service；面板、Docker 或 split 多文件配置不自动修改'
    if [[ "$NE_XRAY_CONFIG" == 'auto' ]]; then
        discover_xray_config
    else
        XRAY_CONFIG="$NE_XRAY_CONFIG"
        [[ -f "$XRAY_CONFIG" && ! -L "$XRAY_CONFIG" ]] || die 'NE_XRAY_CONFIG 不是普通根 JSON 文件'
    fi
    STATE_XRAY_CONFIG="$XRAY_CONFIG"
    run_merger_inspect
    build_xray_candidate
else
    # With no root JSON there is no trustworthy way to infer an inbound tag.
    # Require an operator-specified tag and provide a root merge fragment only.
    if [[ "$NE_INBOUND_TAG" == 'auto' ]]; then
        need_config 'NE_CONFIGURE_XRAY=no 时无法自动发现入站；请显式设置 NE_INBOUND_TAG'
    fi
    build_fragment_candidate
fi

# ----- mutation phase: all discovery and candidate validation above succeeded -----
if ! apply_ssh_changes; then
    rollback_ssh
    die 'SSH 专用账户或 Match 配置未能通过验证，已尝试回滚；未继续部署'
fi

if [[ "$NE_CONFIGURE_XRAY" == 'yes' ]]; then
    if ! install_xray_candidate; then
        rollback_ssh
        die 'Xray 配置已按备份恢复（或恢复重启失败）；SSH 改动已尝试回滚'
    fi
else
    if ! install_fragment; then
        rollback_ssh
        die '无法安装 Xray root 合并片段；SSH 改动已尝试回滚'
    fi
    log_info '未改写或重启 Xray；已生成仅供合并到根配置的 fragment'
fi

if ! write_state; then
    # At this late point live services are valid.  Do not undo the tested Xray
    # change merely because persistence failed; make the incomplete state clear.
    die '服务配置成功但无法写入受管 state.env；请在保留当前管理会话下修复磁盘权限后核验'
fi

# Successful machine-readable output: exactly one value per line and no secret.
printf 'NE_REMOTE_PORT=%s\n' "$REMOTE_PORT"
printf 'NE_HOST_KEY=%s\n' "$HOST_KEY"
printf 'NE_XRAY_STATUS=%s\n' "$XRAY_STATUS"
NE_EMBED_A9A006BF0483700B
cat > "$NE_BUNDLE/xray_merge.py" <<'NE_EMBED_B32DE4A6EBFDBAF3'
#!/usr/bin/env python3
"""Safely merge the nat-egress SOCKS route into one Xray root JSON config.

The program deliberately knows nothing about systemd.  It only reads JSON and
writes a replacement JSON file, which lets setup-jp.sh validate a sibling
candidate before atomically installing it.
"""
from __future__ import annotations

import copy
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

NAT_TAG = "nat-egress"
BLOCK_TAG = "nat-egress-block"
SAFE_PROTOCOLS = {"api", "dokodemo-door"}


class MergeError(ValueError):
    """A configuration cannot be safely changed automatically."""


class NeedConfig(MergeError):
    """Human selection is required; the caller should return status 20."""


def env_required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise MergeError(f"缺少环境变量 {name}")
    return value


def merge_parameters() -> tuple[int, str, str, list[str]]:
    remote_text = env_required("NE_REMOTE_PORT")
    try:
        remote_port = int(remote_text, 10)
    except ValueError as exc:
        raise MergeError("NE_REMOTE_PORT 不是整数") from exc
    if not 1024 <= remote_port <= 65535:
        raise MergeError("NE_REMOTE_PORT 必须在 1024..65535")

    socks_user = env_required("NE_SOCKS_USER")
    socks_pass = env_required("NE_SOCKS_PASS")
    if not re.fullmatch(r"[0-9A-Fa-f]{48}", socks_pass):
        raise MergeError("NE_SOCKS_PASS 必须为 48 位十六进制随机串")

    tag_text = env_required("NE_INBOUND_TAG")
    if tag_text == "auto":
        return remote_port, socks_user, socks_pass, ["auto"]
    tags = [item.strip() for item in tag_text.split(",") if item.strip()]
    if not tags or len(tags) != len(set(tags)):
        raise MergeError("NE_INBOUND_TAG 不能为空或包含重复 tag")
    return remote_port, socks_user, socks_pass, tags


def load_root(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise MergeError(f"无法读取 Xray 配置: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MergeError(f"Xray 配置不是有效 JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise MergeError("Xray 根配置必须是 JSON 对象")
    return raw


def inbound_options(root: dict[str, Any]) -> list[str]:
    inbounds = root.get("inbounds", [])
    if not isinstance(inbounds, list):
        raise MergeError("inbounds 必须是数组")
    options: list[str] = []
    for inbound in inbounds:
        if not isinstance(inbound, dict):
            continue
        protocol = inbound.get("protocol")
        tag = inbound.get("tag")
        if protocol in SAFE_PROTOCOLS or not isinstance(tag, str) or not tag:
            continue
        options.append(tag)
    # Repeated tags are itself unsafe, but report one option only once to the
    # operator rather than producing an ambiguous answer.
    return list(dict.fromkeys(options))


def select_inbound_tags(root: dict[str, Any], requested: list[str]) -> list[str]:
    options = inbound_options(root)
    if requested == ["auto"]:
        if len(options) != 1:
            raise NeedConfig(
                "自动选择需要唯一的可代理入站；请设置 NE_INBOUND_TAG"
            )
        return options
    missing = [tag for tag in requested if tag not in options]
    if missing:
        raise MergeError("指定的 NE_INBOUND_TAG 不存在或属于 api/dokodemo-door")
    return requested


def project_socks_shape(outbound: Any) -> bool:
    """Recognize our tag without accepting an unrelated user-owned outbound."""
    if not isinstance(outbound, dict):
        return False
    if outbound.get("tag") != NAT_TAG or outbound.get("protocol") != "socks":
        return False
    settings = outbound.get("settings")
    if set(outbound) != {"tag", "protocol", "settings", "mux"}:
        return False
    if not isinstance(settings, dict) or set(settings) != {"servers"}:
        return False
    servers = settings.get("servers")
    if not isinstance(servers, list) or len(servers) != 1 or not isinstance(servers[0], dict):
        return False
    server = servers[0]
    if set(server) != {"address", "port", "users"} or server.get("address") != "127.0.0.1":
        return False
    users = server.get("users")
    if (
        not isinstance(server.get("port"), int)
        or not 1024 <= server["port"] <= 65535
        or not isinstance(users, list)
        or len(users) != 1
    ):
        return False
    if not isinstance(users[0], dict) or set(users[0]) != {"user", "pass"}:
        return False
    if (
        not isinstance(users[0].get("user"), str)
        or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", users[0]["user"])
        or not isinstance(users[0].get("pass"), str)
        or not re.fullmatch(r"[0-9A-Fa-f]{48}", users[0]["pass"])
    ):
        return False
    mux = outbound.get("mux")
    return isinstance(mux, dict) and mux == {"enabled": False}


def project_block_shape(outbound: Any) -> bool:
    return (
        isinstance(outbound, dict)
        and set(outbound) == {"tag", "protocol", "settings"}
        and outbound.get("tag") == BLOCK_TAG
        and outbound.get("protocol") == "blackhole"
        and outbound.get("settings") == {}
    )


def desired_outbounds(port: int, user: str, password: str) -> tuple[dict[str, Any], dict[str, Any]]:
    socks = {
        "tag": NAT_TAG,
        "protocol": "socks",
        "settings": {
            "servers": [
                {
                    "address": "127.0.0.1",
                    "port": port,
                    "users": [{"user": user, "pass": password}],
                }
            ]
        },
        "mux": {"enabled": False},
    }
    block = {"tag": BLOCK_TAG, "protocol": "blackhole", "settings": {}}
    return socks, block


def replace_project_outbounds(root: dict[str, Any], port: int, user: str, password: str) -> None:
    outbounds = root.get("outbounds", [])
    if not isinstance(outbounds, list):
        raise MergeError("outbounds 必须是数组")
    desired_socks, desired_block = desired_outbounds(port, user, password)
    found: dict[str, int] = {}
    for index, outbound in enumerate(outbounds):
        if not isinstance(outbound, dict):
            continue
        tag = outbound.get("tag")
        if tag in (NAT_TAG, BLOCK_TAG):
            if tag in found:
                raise MergeError(f"发现重复 outbound tag: {tag}")
            found[tag] = index
            valid = project_socks_shape(outbound) if tag == NAT_TAG else project_block_shape(outbound)
            if not valid:
                raise MergeError(f"已有 {tag} 不是 nat-egress 项目形态，拒绝覆盖")

    # Existing outbound positions are retained.  This is important when the
    # first outbound is a deliberate Xray default route.
    if NAT_TAG in found:
        outbounds[found[NAT_TAG]] = desired_socks
    else:
        outbounds.append(desired_socks)
    if BLOCK_TAG in found:
        outbounds[found[BLOCK_TAG]] = desired_block
    else:
        outbounds.append(desired_block)
    root["outbounds"] = outbounds


def is_project_rule(rule: Any) -> bool:
    if not isinstance(rule, dict) or rule.get("type") != "field":
        return False
    network = rule.get("network")
    outbound = rule.get("outboundTag")
    return (network == "udp" and outbound == BLOCK_TAG) or (
        network == "tcp" and outbound == NAT_TAG
    )


def is_safety_block(rule: Any) -> bool:
    """Keep pre-existing security blocks before the new selected route.

    Xray routing is first-match.  A leading blackhole/private-network rule
    must therefore remain in front of our TCP catch-all.  We intentionally
    only preserve a *leading* safety prefix, so unrelated later rules do not
    get reordered.
    """
    if not isinstance(rule, dict):
        return False
    outbound = rule.get("outboundTag")
    if outbound in {"blackhole", "block", "blocked"}:
        return True
    values: list[str] = []
    for key in ("ip", "domain"):
        value = rule.get(key)
        if isinstance(value, str):
            values.append(value)
        elif isinstance(value, list):
            values.extend(item for item in value if isinstance(item, str))
    return any(item.lower() in {"geoip:private", "private"} for item in values)


def replace_project_rules(root: dict[str, Any], tags: list[str]) -> None:
    routing = root.get("routing")
    if routing is None:
        routing = {}
        root["routing"] = routing
    if not isinstance(routing, dict):
        raise MergeError("routing 必须是对象")
    rules = routing.get("rules", [])
    if not isinstance(rules, list):
        raise MergeError("routing.rules 必须是数组")

    # Remove only unambiguously project-owned rules.  Rules that merely happen
    # to use a similar inbound tag or a generic blackhole are not touched.
    retained = [rule for rule in rules if not is_project_rule(rule)]
    safety_count = 0
    for rule in retained:
        if is_safety_block(rule):
            safety_count += 1
        else:
            break
    project_rules = [
        {
            "type": "field",
            "inboundTag": tags,
            "network": "udp",
            "outboundTag": BLOCK_TAG,
        },
        {
            "type": "field",
            "inboundTag": tags,
            "network": "tcp",
            "outboundTag": NAT_TAG,
        },
    ]
    routing["rules"] = retained[:safety_count] + project_rules + retained[safety_count:]


def merge(root: dict[str, Any]) -> dict[str, Any]:
    port, user, password, requested = merge_parameters()
    tags = select_inbound_tags(root, requested)
    result = copy.deepcopy(root)
    replace_project_outbounds(result, port, user, password)
    replace_project_rules(result, tags)
    return result


def write_json(path: Path, content: dict[str, Any]) -> None:
    path.write_text(json.dumps(content, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def make_fragment() -> dict[str, Any]:
    port, user, password, requested = merge_parameters()
    if requested == ["auto"]:
        raise NeedConfig("fragment 模式无法自动发现入站；请设置 NE_INBOUND_TAG")
    socks, block = desired_outbounds(port, user, password)
    return {
        "outbounds": [socks, block],
        "routing": {
            "rules": [
                {
                    "type": "field",
                    "inboundTag": requested,
                    "network": "udp",
                    "outboundTag": BLOCK_TAG,
                },
                {
                    "type": "field",
                    "inboundTag": requested,
                    "network": "tcp",
                    "outboundTag": NAT_TAG,
                },
            ]
        },
    }


def print_need_config(root: dict[str, Any], reason: str) -> int:
    options = inbound_options(root)
    # These are a machine-readable, deliberately secret-free contract with the
    # shell helper.  stdout must contain no prose on this path.
    print(f"NE_NEED_CONFIG={reason}")
    print("NE_INBOUND_OPTIONS=" + ",".join(options))
    return 20


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 3 and argv[1] == "--inspect":
            root = load_root(Path(argv[2]))
            _, _, _, requested = merge_parameters()
            try:
                select_inbound_tags(root, requested)
            except NeedConfig as exc:
                return print_need_config(root, str(exc))
            return 0
        if len(argv) == 3 and argv[1] == "--fragment":
            try:
                write_json(Path(argv[2]), make_fragment())
            except NeedConfig as exc:
                # There is no root config from which to list choices.
                print(f"NE_NEED_CONFIG={exc}")
                print("NE_INBOUND_OPTIONS=")
                return 20
            return 0
        if len(argv) != 3:
            raise MergeError("用法: xray_merge.py INPUT.json OUTPUT.json | --inspect INPUT.json | --fragment OUTPUT.json")
        root = load_root(Path(argv[1]))
        try:
            result = merge(root)
        except NeedConfig as exc:
            return print_need_config(root, str(exc))
        write_json(Path(argv[2]), result)
        return 0
    except MergeError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"错误：文件操作失败：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
NE_EMBED_B32DE4A6EBFDBAF3
cat > "$NE_BUNDLE/portable.sh" <<'NE_EMBED_CC2BE295B52926D3'
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
NE_EMBED_CC2BE295B52926D3
cat > "$NE_BUNDLE/nat-egress-socks.openrc" <<'NE_EMBED_A2E573256D6B51E5'
#!/sbin/openrc-run

# NAT Egress Lite - loopback SOCKS5 TCP
supervisor=supervise-daemon
command=/usr/local/lib/nat-egress/run-socks
command_user="nat-egress:nat-egress"
export HOME=/var/lib/nat-egress

# The wrapper remains in the foreground; supervise-daemon restarts it after
# an unexpected exit.  The wrapper itself limits its file descriptors to 64.
respawn_delay=10
respawn_max=0
output_log=/dev/null
error_log=/dev/null

depend() {
    need net
}
NE_EMBED_A2E573256D6B51E5
cat > "$NE_BUNDLE/nat-egress-tunnel.openrc" <<'NE_EMBED_B03D1848C2FED2AA'
#!/sbin/openrc-run

# NAT Egress Lite - authenticated reverse SSH tunnel
supervisor=supervise-daemon
command=/usr/local/lib/nat-egress/run-tunnel
command_user="nat-egress:nat-egress"
export HOME=/var/lib/nat-egress

# The wrapper remains in the foreground; supervise-daemon restarts it after
# an unexpected exit.  The wrapper itself limits its file descriptors to 64.
respawn_delay=10
respawn_max=0
output_log=/dev/null
# Send tunnel failures to syslog rather than an unbounded OpenRC log file.
error_logger="logger -t nat-egress-tunnel"

depend() {
    need net nat-egress-socks
}
NE_EMBED_B03D1848C2FED2AA
cat > "$NE_BUNDLE/microsocks.sha256" <<'NE_EMBED_661FD658BD48ACF2'
fd9ab4260972e8c40f7386bec07823d31cb61709bbad0c18d36232a2514c4962  microsocks-linux-amd64
4e3d2eb590d8cdfad84410a854762afcbc8563db54a1bab633153f3a6a30bb38  microsocks-linux-arm64
NE_EMBED_661FD658BD48ACF2
# 此文件是独立 oneclick.sh 的源代码；发布文件由 build-oneclick.py 嵌入其依赖。
set -Eeuo pipefail
if [[ -n ${NE_BUNDLE:-} && -f $NE_BUNDLE/portable.sh ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$NE_BUNDLE/portable.sh"
elif [[ -f $(dirname -- "${BASH_SOURCE[0]}")/portable.sh ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$(dirname -- "${BASH_SOURCE[0]}")/portable.sh"
fi

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

在支持的 Linux 落地机上以 root 运行（自动识别系统和架构）：
  bash oneclick.sh
  或 sh install.sh（在线引导，自动安装缺失的 Bash）

输入入口服务器 地址、可访问的 SSH 端口和管理员用户名即可开始。
落地 SOCKS 端口自动避开已监听端口，也可交互指定；入口反向端口自动选择。
脚本经 SSH 配置入口端并自动生成/校验/备份 Xray 配置，最后启动落地服务。
首次 SSH 连接需要你核对并确认主机指纹；密码在 SSH 提示中现场输入。
入口管理员须是 root，或具备免密 sudo；原生 Xray systemd 服务可自动合并。
不修改当前管理 SSH 端口，不会把 SOCKS 暴露公网。此方案仅支持 TCP。

--help       显示帮助
--dry-run    只说明将执行的操作，不安装、不连接、不修改服务
HELP
}

main() {
    case ${1:-} in --help|-h) help_text; return;; --dry-run) help_text; say '演练模式：没有安装软件、连接服务器或修改配置。'; return;; '') ;; *) fail '未知参数；运行 bash oneclick.sh --help。';; esac
    [[ $EUID -eq 0 ]] || fail '请以 root 运行。'
    [[ -r /dev/tty && -w /dev/tty ]] || fail '需要交互终端；请先保存脚本，再 bash oneclick.sh，不要直接把脚本 pipe 到 bash。'
    [[ $(uname -s) == Linux ]] || fail '目前支持 Linux，不支持原生 Windows/macOS。'
    ne_detect_platform
    ne_detect_init
    [[ $NE_INIT != unsupported ]] || fail '未检测到实际运行的 systemd/OpenRC；无初始化系统的容器暂不支持自动常驻部署。'
    : "${NE_BUNDLE:?请使用构建好的 oneclick.sh，而不是直接执行 setup-head.sh。}"
    umask 077
    say "目标系统：$NE_OS_ID $NE_OS_VERSION / $NE_ARCH / $NE_INIT。不在落地机编译，不安装 Python 或 Docker。"
    say '目前只支持 TCP。监听端口检测不等于商家 NAT 映射或防火墙放行；落地端不需要公网入站映射。'
    free -m
    df -h /
    yes_no '开始安装并配置两端（入口端将备份并修改所选 Xray 配置）？' y || return 0

    ne_install_dependencies || fail '依赖安装失败；请检查软件仓库、网络或可用空间。'
    ne_select_ssh
    say "已选择安全 SSH 后端：$NE_SSH_BACKEND（低版本 Dropbear 不会被强行使用）。"
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
        ask_value '入口服务器 公网 IP 或域名' "$old_host"; jp_host=$REPLY
        [[ $jp_host =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] && break
        say '请填写单个 IP/域名，不带 URL、用户名、方括号或端口。'
    done
    say '入口 SSH 端口不能从落地机直接读取：使用你当前登录入口服务器 的公网端口；它不是 Xray 的入口端口。'
    while true; do
        ask_value '入口服务器 可访问的 SSH 端口' "$old_jp_port"
        if valid_port "$REPLY"; then jp_port=$((10#$REPLY)); break; fi
        say '端口应为 1 到 65535。'
    done
    while true; do
        ask_value '入口服务器 SSH 管理员（root 或具备免密 sudo 的用户）' root; admin_user=$REPLY
        [[ $admin_user =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] && break
    done
    ask_value "管理员 $NE_SSH_BACKEND 私钥路径（留空使用 SSH 密码/默认已有密钥）" ''; admin_key=$REPLY
    [[ -z $admin_key || -r $admin_key ]] || fail '管理员私钥文件不可读；格式必须与所选 SSH 后端一致。'
    say "本机已监听 TCP 端口：$(listen_ports | paste -sd, -)"
    local proposed
    if [[ -n $old_socks_port ]] && valid_port "$old_socks_port" && ne_service_active nat-egress-socks; then
        proposed=$old_socks_port
    else
        proposed=$(free_local_port) || fail '未找到空闲本机端口，请检查监听情况。'
    fi
    while true; do
        ask_value '落地 SOCKS 端口（已自动避开占用，可直接回车）' "$proposed"
        if ! valid_port "$REPLY" || ((10#$REPLY < 1024)); then say '请填写 1024 到 65535。'; continue; fi
        socks_port=$((10#$REPLY))
        if port_busy "$socks_port"; then
            if [[ $socks_port == "$old_socks_port" ]] && ne_service_active nat-egress-socks; then break; fi
            say "端口 $socks_port 已占用，请换一个；不会关闭其他进程。"
        else break; fi
    done
    while true; do
        ask_value '入口反向监听端口（0=在入口自动选空闲端口）' 0
        if [[ $REPLY == 0 ]]; then remote_port=0; break; fi
        if valid_port "$REPLY" && ((10#$REPLY >= 1024)); then remote_port=$((10#$REPLY)); break; fi
        say '输入 0 自动选择，或填写 1024 到 65535。'
    done
    if yes_no '自动对接入口的原生 Xray 服务？' y; then configure_xray=yes; else configure_xray=no; fi
    ask_value '入口 Xray 单文件 JSON 路径（回车自动识别）' auto; xray_config=$REPLY
    if [[ $configure_xray == yes ]]; then
        ask_value '要使用落地的 Xray 入站 tag（回车自动识别唯一入口）' auto
    else
        ask_value '要使用落地的 Xray 入站 tag（不自动修改 Xray 时必须填写）' ''
    fi
    inbound_tag=$REPLY
    [[ -n $inbound_tag ]] || fail '入站 tag 不能为空。'
    [[ $xray_config == auto || $xray_config == /* ]] || fail 'Xray 配置路径必须为绝对路径或 auto。'
    [[ $xray_config != *$'\n'* && $inbound_tag != *$'\n'* ]] || fail '路径/tag 不得含换行。'

    ne_create_account nat-egress nat-egress /var/lib/nat-egress || fail '无法创建安全的服务账户。'
    install -d -o nat-egress -g nat-egress -m 0700 /var/lib/nat-egress/.ssh
    local key_file="/var/lib/nat-egress/.ssh/$NE_KEY_NAME"
    if [[ ! -s $key_file ]]; then
        if [[ $NE_SSH_BACKEND == dropbear ]]; then
            ne_run_as nat-egress dropbearkey -t ed25519 -f "$key_file" >/dev/null
        else
            ne_run_as nat-egress ssh-keygen -q -t ed25519 -N '' -f "$key_file"
        fi
    fi
    local public_key socks_pass request response remote_command rc attempt actual_port host_key xray_status
    if [[ $NE_SSH_BACKEND == dropbear ]]; then
        public_key=$(ne_run_as nat-egress dropbearkey -y -f "$key_file" | awk '/^ssh-ed25519 / {print $1 " " $2; exit}')
    else
        public_key=$(ne_run_as nat-egress ssh-keygen -y -f "$key_file" | awk '{print $1 " " $2}')
    fi
    [[ -n $public_key ]] || fail '无法提取落地公钥。'
    socks_pass=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
    request=$NE_BUNDLE/request.sh; response=$NE_BUNDLE/response.log
    remote_command='bash -s'
    [[ $admin_user == root ]] || remote_command='sudo -n bash -s'
    local ssh_client ssh_args=(-T -o StrictHostKeyChecking=ask -o BatchMode=no -p "$jp_port" -l "$admin_user")
    if [[ $NE_SSH_BACKEND == dropbear ]]; then ssh_client=dbclient; ssh_args+=(-K 20)
    else ssh_client=ssh; ssh_args+=(-o ServerAliveInterval=20); fi
    [[ -z $admin_key ]] || ssh_args+=(-i "$admin_key")
    say '连接入口服务器；首次连接请通过可信控制台核对显示的主机指纹，再确认。SSH 密码直接在 SSH 提示中输入。'
    for ((attempt=1; attempt<=4; attempt++)); do
        {
            # 入口端执行时才展开这些变量，不在本机展开。
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
        "$ssh_client" "${ssh_args[@]}" "$jp_host" "$remote_command" < "$request" | tee "$response"
        rc=${PIPESTATUS[0]}
        set -e
        if ((rc==0)); then break; fi
        if ((rc==20 && attempt<4)); then
            if [[ -n $(sed -n 's/^NE_INBOUND_OPTIONS=//p' "$response" | tail -1) ]]; then
                say "检测到多个入口：$(sed -n 's/^NE_INBOUND_OPTIONS=//p' "$response")"
                ask_value '请选择一个实际入站 tag' ''; inbound_tag=$REPLY
                [[ -n $inbound_tag && $inbound_tag != *$'\n'* ]] || fail '入口 tag 无效。'
            elif grep -q '^NE_NEED_CONFIG=' "$response"; then
                say '自动识别存在歧义，请根据入口端输出填写明确的原生 Xray 配置路径。'
                ask_value '入口 Xray 配置绝对路径' ''; xray_config=$REPLY
                [[ $xray_config == /* && $xray_config != *$'\n'* ]] || fail '配置路径无效。'
            else fail '入口端要求额外配置，请检查上面的说明。'; fi
            continue
        fi
        fail '入口端未配置成功；本机未启用新服务。请处理 SSH/权限/Xray 错误后重新运行。'
    done
    actual_port=$(sed -n 's/^NE_REMOTE_PORT=//p' "$response" | tail -1)
    host_key=$(sed -n 's/^NE_HOST_KEY=//p' "$response" | tail -1)
    xray_status=$(sed -n 's/^NE_XRAY_STATUS=//p' "$response" | tail -1)
    valid_port "$actual_port" || fail '入口端没有返回有效反向端口。'
    [[ $host_key =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,3}$ ]] || fail '入口端没有返回有效的 Ed25519 主机公钥。'
    [[ $xray_status == merged || $xray_status == fragment ]] || fail '入口端 Xray 状态不完整。'

    install -d -o root -g nat-egress -m 0750 /etc/nat-egress
    if [[ -e /etc/nat-egress/egress.conf ]]; then cp -p /etc/nat-egress/egress.conf "/etc/nat-egress/egress.conf.backup.$(date +%s)"; fi
    {
        printf "SSH_BACKEND='%s'\nJP_HOST='%s'\nJP_PORT='%s'\nJP_USER='nat-tunnel'\n" "$NE_SSH_BACKEND" "$jp_host" "$jp_port"
        printf "REMOTE_PORT='%s'\nSOCKS_PORT='%s'\nSOCKS_USER='egress'\nSOCKS_PASS='%s'\nSSH_WINDOW='32768'\nSSH_KEEPALIVE='20'\n" "$actual_port" "$socks_port" "$socks_pass"
    } > /etc/nat-egress/egress.conf
    chown root:nat-egress /etc/nat-egress/egress.conf
    chmod 0640 /etc/nat-egress/egress.conf
    local host_field=$jp_host
    if [[ $NE_SSH_BACKEND == openssh && $jp_port != 22 ]]; then host_field="[$jp_host]:$jp_port"; fi
    printf '%s %s\n' "$host_field" "$host_key" > /var/lib/nat-egress/.ssh/known_hosts
    chown nat-egress:nat-egress /var/lib/nat-egress/.ssh/known_hosts
    chmod 0600 /var/lib/nat-egress/.ssh/known_hosts
    install -d -m 0755 /usr/local/lib/nat-egress
    install -m 0755 "$NE_BUNDLE/run-socks" "$NE_BUNDLE/run-tunnel" /usr/local/lib/nat-egress/
    ne_install_services "$NE_BUNDLE" || fail '服务注册失败。'
    ne_start_services || fail '服务启动失败。'
    local ready=no
    for ((attempt=0; attempt<15; attempt++)); do
        if ne_service_active nat-egress-socks && ne_service_active nat-egress-tunnel; then ready=yes; break; fi
        sleep 1
    done
    [[ $ready == yes ]] || fail '本机服务启动失败，请检查 systemctl/rc-service 和日志；入口端配置已完成。'
    say "本机服务已启动：落地 127.0.0.1:$socks_port，入口反向 127.0.0.1:$actual_port。"
    say '服务 active 不等于端到端健康；请在客户端验证实际出口，不能据此保证 64 MB 稳定或没有 DNS 泄漏。'
    if [[ $xray_status == merged ]]; then
        say '入口 Xray 已自动合并、校验并重载。现有客户端连接方式保持不变；选定入口的 TCP 走落地，UDP 阻断。'
    else
        say '你选择了不自动修改 Xray：入口端仅生成 /etc/nat-egress-jp/xray-fragment.json，尚未完成入口对接。'
    fi
    say '不需要打开落地 NAT 公网端口；没有修改入口管理 SSH 监听端口。'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
