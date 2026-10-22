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
pieces.append(head.split('\n', 1)[1])
target = root / 'oneclick.sh'
target.write_text(''.join(pieces))
target.chmod(0o755)
print(f'{target}: {target.stat().st_size} bytes; 6 resources embedded')
