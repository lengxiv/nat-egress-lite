#!/usr/bin/env bash
# Portable API tests: all package/service calls are mocked; no apt/apk/dnf or real service is run.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../scripts/portable.sh
. "$ROOT/scripts/portable.sh"
pass=0; fail=0
ok() { printf 'ok - %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'not ok - %s\n' "$1"; fail=$((fail+1)); }

# Architecture mapping is driven by a mocked uname and does not alter host state.
uname() { printf '%s\n' "${MOCK_UNAME:-x86_64}"; }
MOCK_UNAME=x86_64 ne_detect_platform; [ "$NE_ARCH" = amd64 ] && ok amd64 || bad amd64
MOCK_UNAME=aarch64 ne_detect_platform; [ "$NE_ARCH" = arm64 ] && ok arm64 || bad arm64
MOCK_UNAME=riscv64 ne_detect_platform; [ "$NE_ARCH" = riscv64 ] && ok unknown-arch-preserved || bad unknown-arch-preserved

# Package calls are captured instead of executed.
ne_package_install() { PKG_CALL="$*"; return 0; }
NE_PACKAGE_MANAGER=apk
ne_package_install dropbear openssh-client-default iproute2 microsocks
[[ "$PKG_CALL" == *"dropbear openssh-client-default iproute2 microsocks"* ]] && ok apk-package-family || bad apk-package-family
NE_PACKAGE_MANAGER=apt; ne_package_install dropbear-bin openssh-client iproute2 microsocks passwd util-linux
[[ "$PKG_CALL" == *"dropbear-bin openssh-client iproute2 microsocks"* ]] && ok apt-package-family || bad apt-package-family
NE_PACKAGE_MANAGER=dnf; ne_package_install openssh-clients iproute shadow-utils
[[ "$PKG_CALL" == *"openssh-clients iproute shadow-utils"* ]] && ok dnf-package-family || bad dnf-package-family
NE_PACKAGE_MANAGER=yum; ne_package_install openssh-clients iproute shadow-utils
[[ "$PKG_CALL" == *"openssh-clients iproute shadow-utils"* ]] && ok yum-package-family || bad yum-package-family

# SSH selection must reject old Dropbear help output and select OpenSSH.
PATH="$ROOT/tests/mock-portable-bin:$PATH"; mkdir -p "$ROOT/tests/mock-portable-bin"
cat > "$ROOT/tests/mock-portable-bin/dbclient" <<'EOF'
#!/bin/sh
printf '%s\n' 'Usage: dbclient [-o option]' # deliberately lacks required options
EOF
chmod 755 "$ROOT/tests/mock-portable-bin/dbclient"
ne_select_ssh; [ "$NE_SSH_BACKEND" = openssh ] && [ "$NE_KEY_NAME" = id_ed25519 ] && ok old-dropbear-fallback || bad old-dropbear-fallback
rm -rf "$ROOT/tests/mock-portable-bin"

# OpenRC branch uses mocked init tools; no rc-update/rc-service is actually called.
rc-service() { return 0; }; rc-update() { return 0; }
cat() { case "${1-}" in /proc/1/comm) printf 'init\n';; *) builtin cat "$@";; esac; }
NE_INIT=unsupported; ne_detect_init >/dev/null 2>&1
[ "$NE_INIT" = openrc ] && ok openrc-detection || bad openrc-detection

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
