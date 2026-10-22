#!/usr/bin/env python3
"""只执行临时复制版的日本端预检，所有系统服务与账户命令均替身。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class JapanesePreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ne-preflight-')
        self.path = Path(self.tmp.name)
        self.bin = self.path / 'bin'
        self.bin.mkdir()
        self.host = self.path / 'host'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.host)], check=True)
        self.config = self.path / 'xray.json'
        self.config.write_text(json.dumps({'inbounds': [{'tag': 'entry', 'protocol': 'socks', 'settings': {'auth': 'noauth'}}], 'outbounds': [{'tag': 'direct', 'protocol': 'freedom'}]}))
        self.ssh_config = self.path / 'sshd_config'
        self.ssh_config.write_text('Include /etc/ssh/sshd_config.d/*.conf\n')
        self.dropins = self.path / 'sshd_config.d'
        self.dropins.mkdir()
        self.work = self.path / 'work'
        self.work.mkdir()
        shutil.copy2(ROOT / 'scripts/xray_merge.py', self.work / 'xray_merge.py')
        source = (ROOT / 'scripts/setup-jp.sh').read_text().split('# ----- mutation phase:')[0]
        source = source.replace("readonly TUNNEL_HOME='/var/lib/nat-tunnel'", f"readonly TUNNEL_HOME='{self.path}/tunnel-home'")
        source = source.replace("readonly SSHD_CONFIG='/etc/ssh/sshd_config'", f"readonly SSHD_CONFIG='{self.ssh_config}'")
        source = source.replace("readonly SSHD_DROPIN_DIR='/etc/ssh/sshd_config.d'", f"readonly SSHD_DROPIN_DIR='{self.dropins}'")
        source = source.replace("readonly STATE_DIR='/etc/nat-egress-jp'", f"readonly STATE_DIR='{self.path}/state'")
        source += '\nprintf "TEST_PORT=%s\\nTEST_KEY=%s\\n" "$REMOTE_PORT" "$HOST_KEY"\n'
        self.script = self.path / 'preflight.sh'
        self.script.write_text(source)
        scripts = {
            'id': 'echo 0',
            'getent': 'exit 2',
            'ss': "printf '%s\\n' 'LISTEN 0 128 [::]:19080 [::]:*' 'LISTEN 0 128 0.0.0.0:1080 0.0.0.0:*'",
            'sshd': f"printf 'hostkey %s\\n' '{self.host}'",
            'xray': 'exit 0',
            'systemctl': f"case \"$*\" in *ExecStart*) printf '%s\\n' '{{ path={self.bin}/xray ; argv[]={self.bin}/xray run -config {self.config} ; }}';; *LoadState*) echo loaded;; *) exit 0;; esac",
        }
        for name, text in scripts.items():
            target = self.bin / name
            target.write_text('#!/bin/bash\n' + text + '\n')
            target.chmod(0o755)
        public = ' '.join(self.host.with_suffix('.pub').read_text().split()[:2])
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', NE_WORK_DIR=str(self.work), NE_PUBLIC_KEY=public, NE_REMOTE_PORT='0', NE_SOCKS_USER='egress', NE_SOCKS_PASS='a' * 48, NE_XRAY_CONFIG='auto', NE_INBOUND_TAG='auto', NE_CONFIGURE_XRAY='yes')

    def tearDown(self):
        self.tmp.cleanup()

    def run_preflight(self):
        return subprocess.run(['bash', str(self.script)], env=self.env, text=True, capture_output=True, timeout=15)

    def test_auto_port_and_actual_enabled_host_key(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        port = int(next(line.split('=', 1)[1] for line in result.stdout.splitlines() if line.startswith('TEST_PORT=')))
        self.assertGreaterEqual(port, 49152)
        self.assertLessEqual(port, 65535)
        self.assertNotEqual(port, 19080)
        self.assertIn('TEST_KEY=' + self.env['NE_PUBLIC_KEY'], result.stdout)
        self.assertFalse((self.path / 'state').exists())
        self.assertFalse((self.path / 'tunnel-home').exists())

    def test_multiple_inbounds_request_selection_without_changes(self):
        original = json.dumps({'inbounds': [{'tag': 'a', 'protocol': 'socks'}, {'tag': 'b', 'protocol': 'socks'}], 'outbounds': [{'protocol': 'freedom'}]})
        self.config.write_text(original)
        result = self.run_preflight()
        self.assertEqual(result.returncode, 20, result.stdout + result.stderr)
        self.assertIn('NE_INBOUND_OPTIONS=a,b', result.stdout)
        self.assertEqual(self.config.read_text(), original)
        self.assertFalse((self.path / 'state').exists())

    def test_explicit_occupied_port_rejected(self):
        self.env['NE_REMOTE_PORT'] = '19080'
        result = self.run_preflight()
        self.assertEqual(result.returncode, 1)
        self.assertIn('已被', result.stderr)
        self.assertFalse((self.path / 'state').exists())


if __name__ == '__main__':
    unittest.main()
