#!/usr/bin/env python3
"""仅在开发机执行：打包源码项目，不包含密钥或本机编译产物。"""
from pathlib import Path
import tarfile
import zipfile

root = Path(__file__).resolve().parent
out = root.parent / 'output'
out.mkdir(exist_ok=True)
files = []
for p in sorted(root.rglob('*')):
    if not p.is_file():
        continue
    rel = p.relative_to(root)
    if any(part in {'.git', '__pycache__'} for part in rel.parts):
        continue
    if p.name in {'microsocks', 'config.mak'} or p.suffix in {'.o', '.pyc'}:
        continue
    if p.name in {'egress.conf', 'known_hosts', 'id_dropbear', '.env'} or p.suffix in {'.pem', '.key'}:
        continue
    files.append(p)
for required in ('README.md', 'install-debian.sh', 'config/xray-fragment.json',
                 'docs/test-results.md', 'tests/integration.py', 'docs/wireguard.md',
                 'vendor/microsocks/COPYING', 'vendor/microsocks/sockssrv.c'):
    if not root.joinpath(required).is_file():
        raise SystemExit(f'缺少交付文件：{required}')
with zipfile.ZipFile(out / 'nat-egress-lite.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for p in files:
        z.write(p, str(Path(root.name) / p.relative_to(root)))
with tarfile.open(out / 'nat-egress-lite.tar.gz', 'w:gz') as t:
    for p in files:
        t.add(p, arcname=str(Path(root.name) / p.relative_to(root)), recursive=False)
for p in (out / 'nat-egress-lite.zip', out / 'nat-egress-lite.tar.gz'):
    print(f'{p}: {p.stat().st_size} bytes, {len(files)} source files')
