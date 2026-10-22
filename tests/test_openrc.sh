#!/usr/bin/env bash
# Static checks only: this test deliberately does not invoke OpenRC or start a service.
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
socks="$project_root/deploy/nat-egress-socks.openrc"
tunnel="$project_root/deploy/nat-egress-tunnel.openrc"

fail() {
    printf 'test_openrc.sh: %s\n' "$*" >&2
    exit 1
}

require_line() {
    local file=$1 line=$2
    grep -Fqx -- "$line" "$file" || fail "missing '$line' in ${file#$project_root/}"
}

for service in "$socks" "$tunnel"; do
    [[ -x $service ]] || fail "not executable: ${service#$project_root/}"
    bash -n "$service"
    require_line "$service" '#!/sbin/openrc-run'
    require_line "$service" 'supervisor=supervise-daemon'
    require_line "$service" 'command_user="nat-egress:nat-egress"'
    require_line "$service" 'export HOME=/var/lib/nat-egress'
    require_line "$service" 'respawn_delay=10'
    require_line "$service" 'respawn_max=0'
    if grep -Eq '(^|[[:space:]])(command_background|daemonize)=' "$service"; then
        fail "backgrounding conflicts with supervise-daemon: ${service#$project_root/}"
    fi
    if grep -Eq '(^|[[:space:]])pidfile=' "$service"; then
        fail "pidfile-based pseudo-service is not permitted: ${service#$project_root/}"
    fi
done

require_line "$socks" 'command=/usr/local/lib/nat-egress/run-socks'
require_line "$socks" 'output_log=/dev/null'
require_line "$socks" 'error_log=/dev/null'
require_line "$socks" '    need net'

require_line "$tunnel" 'command=/usr/local/lib/nat-egress/run-tunnel'
require_line "$tunnel" 'output_log=/dev/null'
require_line "$tunnel" 'error_logger="logger -t nat-egress-tunnel"'
require_line "$tunnel" '    need net nat-egress-socks'

printf '%s\n' 'OpenRC static checks passed (no OpenRC service was started).'
