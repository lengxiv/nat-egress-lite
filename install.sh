#!/bin/sh
# 通用 Linux 引导入口；只按实际包管理器补齐 Bash，然后启动独立安装器。
set -eu
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
[ "$(uname -s)" = Linux ] || { echo '此项目目前支持 Linux，不支持原生 Windows/macOS。' >&2; exit 1; }
if ! command -v bash >/dev/null 2>&1; then
    echo '检测到缺少 Bash，正在通过本机软件仓库安装。'
    if command -v apk >/dev/null 2>&1; then apk add --no-cache bash
    elif command -v apt-get >/dev/null 2>&1; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash
    elif command -v dnf >/dev/null 2>&1; then dnf install -y bash
    elif command -v yum >/dev/null 2>&1; then yum install -y bash
    else echo '没有受支持的包管理器，请先安装 Bash。' >&2; exit 1; fi
fi
umask 077
file=$(mktemp /tmp/nat-egress.XXXXXX)
trap 'rm -f -- "$file"' EXIT HUP INT TERM
url='https://raw.githubusercontent.com/lengxiv/nat-egress-lite/main/oneclick.sh'
if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$file"
elif command -v wget >/dev/null 2>&1; then wget -O "$file" "$url"
else echo '需要已有 curl 或 wget 以下载安装器。' >&2; exit 1; fi
bash "$file" "$@"
