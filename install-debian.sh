#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo '请以 root 执行。' >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
if [ "$ID" != debian ] || [ "$VERSION_ID" != 13 ]; then
    echo '此安装器面向 Debian 13。' >&2
    exit 1
fi
[ "$(cat /proc/1/comm)" = systemd ] || { echo 'PID 1 不是 systemd；请勿套用此安装器。' >&2; exit 1; }
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
echo "目标架构：$(dpkg --print-architecture)；安装 Debian 官方 microsocks 与 dropbear-bin，无编译、无 Docker。"
echo '先确认磁盘和内存余量；安装过程也可能触发 64 MB 容器 OOM。'
free -m
df -h /
# 不安装 dropbear 服务端，也不改现有 SSH 服务。
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends microsocks dropbear-bin
apt-get clean
if ! id nat-egress >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /var/lib/nat-egress --create-home --shell /usr/sbin/nologin nat-egress
fi
install -d -m 0755 /usr/local/lib/nat-egress
install -m 0755 "$ROOT/bin/run-socks" "$ROOT/bin/run-tunnel" /usr/local/lib/nat-egress/
install -d -o root -g nat-egress -m 0750 /etc/nat-egress
if [ ! -e /etc/nat-egress/egress.conf ]; then
    install -o root -g nat-egress -m 0640 "$ROOT/config/egress.conf.example" /etc/nat-egress/egress.conf
fi
install -d -o nat-egress -g nat-egress -m 0700 /var/lib/nat-egress /var/lib/nat-egress/.ssh
if [ ! -e /var/lib/nat-egress/.ssh/id_dropbear ]; then
    runuser -u nat-egress -- dropbearkey -t ed25519 -f /var/lib/nat-egress/.ssh/id_dropbear
fi
chmod 0600 /var/lib/nat-egress/.ssh/id_dropbear
install -m 0644 "$ROOT/deploy/nat-egress-socks.service" "$ROOT/deploy/nat-egress-tunnel.service" /etc/systemd/system/
systemctl daemon-reload
# 有意不自动启动：必须先配置凭据与经过核验的日本 VPS 主机密钥。
echo '文件已安装，服务尚未启用。请按 README 配置两端后再启动。'
echo '落地公钥（可发到日本 VPS；不要复制私钥）：'
runuser -u nat-egress -- dropbearkey -y -f /var/lib/nat-egress/.ssh/id_dropbear | sed -n '/^ssh-/p'
