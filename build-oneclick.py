#!/usr/bin/env python3
"""开发机执行：生成不依赖 Git/curl/外部源码目录的 oneclick.sh。"""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent
resources = {
    'run-socks': 'bin/run-socks',
    'run-tunnel': 'bin/run-tunnel',
    'nat-egress-socks.service': 'deploy/nat-egress-socks.service',
    'nat-egress-tunnel.service': 'deploy/nat-egress-tunnel.service',
    'setup-jp.sh': 'scripts/setup-jp.sh',
    'xray_merge.py': 'scripts/xray_merge.py',
    'portable.sh': 'scripts/portable.sh',
    'nat-egress-socks.openrc': 'deploy/nat-egress-socks.openrc',
    'nat-egress-tunnel.openrc': 'deploy/nat-egress-tunnel.openrc',
    'microsocks.sha256': 'config/microsocks.sha256',
    'vless-setup.sh': 'scripts/vless-setup.sh',
    'vless-config.sh': 'scripts/vless-config.sh',
    'run-vless': 'bin/run-vless',
    'nat-egress-vless.service': 'deploy/nat-egress-vless.service',
    'nat-egress-vless.openrc': 'deploy/nat-egress-vless.openrc',
    'xray.sha256': 'config/xray.sha256',
}
head = root.joinpath('scripts/setup-head.sh').read_text()
pieces = ['#!/usr/bin/env bash\nset -Eeuo pipefail\numask 077\n',
          'NE_BUNDLE=$(mktemp -d /tmp/ne-install.XXXXXX)\n',
          'trap \'rm -rf -- "$NE_BUNDLE"\' EXIT\n']
for name, source in resources.items():
    text = root.joinpath(source).read_text()
    delimiter = 'NE_EMBED_' + hashlib.sha256(text.encode()).hexdigest()[:16].upper()
    if delimiter in text.splitlines():
        raise ValueError('heredoc delimiter collision')
    pieces.append(f'cat > "$NE_BUNDLE/{name}" <<\'{delimiter}\'\n{text.rstrip()}\n{delimiter}\n')
guard = 'if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi'
dispatch = '''# 默认部署用户需要的 VLESS 节点；旧反向 SSH 为可选兼容模式。
# shellcheck disable=SC1090,SC1091
source "$NE_BUNDLE/vless-config.sh"
# shellcheck disable=SC1090,SC1091
source "$NE_BUNDLE/vless-setup.sh"
if [[ ${1:-} == --ssh ]]; then
    shift
    main "$@"
else
    nv_main "$@"
fi'''
assert head.count(guard) == 1, 'main dispatch guard changed'
pieces.append(head.split('\n', 1)[1].replace(guard, dispatch))
target = root / 'oneclick.sh'
target.write_text(''.join(pieces))
target.chmod(0o755)
print(f'{target}: {target.stat().st_size} bytes; {len(resources)} resources embedded')
