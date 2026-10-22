#!/usr/bin/env bash
# 仅用于资源充足的开发机；64 MB 部署端不编译。
set -Eeuo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:?请指定开发机输出目录}
mkdir -p "$OUT/toolchains"
[[ $(uname -m) == aarch64 ]] || { echo '此可复现构建脚本针对 ARM64 开发机与 AMD64 交叉工具链。' >&2; exit 1; }
archive="$OUT/musl-1.2.6.tar.gz"
patchfile="$OUT/musl-iconv-fix.patch"
curl -fsSL https://musl.libc.org/releases/musl-1.2.6.tar.gz -o "$archive"
curl -fsSL https://www.openwall.com/lists/musl/2026/04/03/2/1 -o "$patchfile"
for arch in arm64 amd64; do
    source="$OUT/toolchains/source-$arch"
    prefix="$OUT/toolchains/musl-$arch"
    if [[ $arch == arm64 ]]; then
        compiler='gcc'; target=aarch64-linux-musl; archiver='ar'; indexer='ranlib'
    else
        compiler=x86_64-linux-gnu-gcc; target=x86_64-linux-musl
        archiver=x86_64-linux-gnu-ar; indexer=x86_64-linux-gnu-ranlib
    fi
    if [[ ! -f $source/config.mak ]]; then
        mkdir -p "$source"
        tar -xzf "$archive" --strip-components=1 -C "$source"
        (cd "$source" && patch -p1 < "$patchfile")
        (cd "$source" && CC="$compiler" ./configure --target="$target" --prefix="$prefix" --disable-shared) > "$OUT/musl-$arch-build.log" 2>&1
    fi
    echo "构建 $arch 静态 musl（详细编译日志写入输出目录）"
    (cd "$source" && make -j4 AR="$archiver" RANLIB="$indexer" && make AR="$archiver" RANLIB="$indexer" install) >> "$OUT/musl-$arch-build.log" 2>&1
    "$prefix/bin/musl-gcc" -Os -std=c99 -Wno-unknown-pragmas -static -s \
        "$ROOT/vendor/microsocks/sockssrv.c" "$ROOT/vendor/microsocks/server.c" \
        "$ROOT/vendor/microsocks/sblist.c" "$ROOT/vendor/microsocks/sblist_delete.c" \
        -lpthread -o "$OUT/microsocks-linux-$arch"
    echo "$arch 组件构建完成"
done
(cd "$OUT" && sha256sum microsocks-linux-amd64 microsocks-linux-arm64 > microsocks.sha256 && sha256sum musl-1.2.6.tar.gz musl-iconv-fix.patch > SOURCES.sha256)
cp "$OUT/microsocks.sha256" "$ROOT/config/microsocks.sha256"
cp "$OUT/toolchains/source-arm64/COPYRIGHT" "$OUT/musl-COPYRIGHT"
cp "$ROOT/vendor/microsocks/COPYING" "$OUT/microsocks-LICENSE"
cp "$OUT/musl-COPYRIGHT" "$ROOT/vendor/musl-COPYRIGHT"
file "$OUT/microsocks-linux-amd64" "$OUT/microsocks-linux-arm64"
cat "$OUT/microsocks.sha256"
