#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ ! -f "$ROOT/oneclick.sh" ]; then
    echo '缺少 oneclick.sh；请下载完整源码包，或直接下载独立 oneclick.sh。' >&2
    exit 1
fi
exec bash "$ROOT/oneclick.sh" "$@"
