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
