#!/usr/bin/env python3
"""Isolated integration checks for nat-egress-lite.

This script must be run on a Linux host with sudo/root access.  It creates a
unique temporary account, an OpenSSH server and all credentials under a new
/tmp directory.  It does not read or alter the system sshd configuration,
keys, or any pre-existing service.  All listeners use 127.0.0.1 and randomly
allocated high ports.  Every created process and the temporary account are
removed in ``finally``.
"""

from __future__ import annotations

import argparse
import json
import os
import pwd
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable


PROJECT = Path(__file__).resolve().parents[1]
RUN_SOCKS = PROJECT / "bin" / "run-socks"
RUN_TUNNEL = PROJECT / "bin" / "run-tunnel"
MICROSOCKS = PROJECT / "vendor" / "microsocks" / "microsocks"
XRAY_FRAGMENT = PROJECT / "config" / "xray-fragment.json"


class TestFailure(RuntimeError):
    """A required test condition was not met."""


@dataclass
class ManagedProcess:
    name: str
    popen: subprocess.Popen[str]
    log: Path


class ResultLog:
    def __init__(self) -> None:
        self.rows: list[dict[str, str]] = []

    def progress(self, message: str) -> None:
        print(f"[integration] {message}", flush=True)

    def add(self, name: str, status: str, detail: str) -> None:
        self.rows.append({"name": name, "status": status, "detail": detail})
        self.progress(f"{status}: {name} — {detail}")

    def passed(self, name: str, detail: str) -> None:
        self.add(name, "PASS", detail)

    def failed(self, name: str, detail: str) -> None:
        self.add(name, "FAIL", detail)

    def skipped(self, name: str, detail: str) -> None:
        self.add(name, "SKIP", detail)


def command_text(command: list[str], *, timeout: int = 30, check: bool = True) -> str:
    completed = subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    if check and completed.returncode:
        raise TestFailure(
            f"命令失败 ({completed.returncode}): {' '.join(command)}\n{completed.stdout.strip()}"
        )
    return completed.stdout


def require_program(name: str) -> str:
    found = shutil.which(name)
    if not found:
        raise TestFailure(f"缺少必需命令: {name}")
    return found


def random_loopback_port(used: set[int]) -> int:
    """Reserve-check a random high TCP port, then release it for the test service."""
    for _ in range(200):
        candidate = secrets.randbelow(65535 - 49152 + 1) + 49152
        if candidate in used:
            continue
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
            probe.bind(("127.0.0.1", candidate))
        except OSError:
            continue
        finally:
            probe.close()
        used.add(candidate)
        return candidate
    raise TestFailure("无法找到空闲随机高位回环端口")


def recv_exact(sock: socket.socket, length: int) -> bytes:
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            break
        data += part
    return data


def socks_auth(remote_port: int, user: str, password: str) -> socket.socket:
    sock = socket.create_connection(("127.0.0.1", remote_port), timeout=5)
    sock.settimeout(5)
    sock.sendall(b"\x05\x01\x02")
    if recv_exact(sock, 2) != b"\x05\x02":
        sock.close()
        raise TestFailure("SOCKS 服务未选择用户名/密码认证")
    user_b = user.encode("ascii")
    pass_b = password.encode("ascii")
    sock.sendall(bytes([1, len(user_b)]) + user_b + bytes([len(pass_b)]) + pass_b)
    reply = recv_exact(sock, 2)
    if reply != b"\x01\x00":
        sock.close()
        raise TestFailure(f"正确 SOCKS 凭据被拒绝: {reply!r}")
    return sock


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (method name prescribed by stdlib)
        body = b"NAT-EGRESS-INTEGRATION-OK\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        pass


class ThreadingHTTPServerV6(ThreadingHTTPServer):
    """An IPv6-loopback counterpart for localhost SOCKS name resolution."""

    address_family = socket.AF_INET6


class IsolatedIntegration:
    def __init__(self, *, keep_logs: bool) -> None:
        self.results = ResultLog()
        self.keep_logs = keep_logs
        # dbclient 2022.83 uses fixed-size buffers for some identity-related
        # strings, so keep the otherwise fully isolated temporary HOME short.
        self.root = Path(tempfile.mkdtemp(prefix="neit-", dir="/tmp"))
        os.chmod(self.root, 0o755)
        self.home = self.root / "home"
        self.bin_dir = self.root / "bin"
        self.ssh_dir = self.home / ".ssh"
        self.logs_dir = self.root / "logs"
        self.processes: list[ManagedProcess] = []
        self.httpd: ThreadingHTTPServer | None = None
        self.http_thread: threading.Thread | None = None
        self.httpd_v6: ThreadingHTTPServerV6 | None = None
        self.http_thread_v6: threading.Thread | None = None
        self.user = f"natit{secrets.token_hex(5)}"[:20]
        self.created_user = False
        self.ports: dict[str, int] = {}
        self.password = "p" + secrets.token_hex(24)
        self.conf = self.root / "egress.conf"
        self.good_known_hosts = self.ssh_dir / "known_hosts.good"
        self.current_tunnel: ManagedProcess | None = None

    def setup_binaries_and_account(self) -> None:
        self.results.progress("检查依赖并创建临时测试账户")
        for item in (RUN_SOCKS, RUN_TUNNEL, MICROSOCKS, XRAY_FRAGMENT):
            if not item.is_file():
                raise TestFailure(f"项目文件不存在: {item}")
        for program in ("runuser", "useradd", "userdel", "ssh-keygen", "dropbearkey", "sshd", "curl", "ss"):
            require_program(program)

        self.bin_dir.mkdir(mode=0o755)
        self.logs_dir.mkdir(mode=0o755)
        for source, target in (
            (RUN_SOCKS, self.bin_dir / "run-socks"),
            (RUN_TUNNEL, self.bin_dir / "run-tunnel"),
            (MICROSOCKS, self.bin_dir / "microsocks"),
        ):
            shutil.copy2(source, target)
            os.chmod(target, 0o755)

        # No new group is created.  The account has its actual home at self.home,
        # which matters because dbclient resolves HOME via getpwuid(3).
        command_text(
            [
                "useradd",
                "--password",
                "*",
                "--shell",
                "/usr/sbin/nologin",
                "--home-dir",
                str(self.home),
                "--create-home",
                "--no-user-group",
                "--gid",
                "nogroup",
                self.user,
            ]
        )
        self.created_user = True
        account = pwd.getpwnam(self.user)
        if Path(account.pw_dir) != self.home:
            raise TestFailure("临时账户 HOME 与请求的临时目录不一致")
        self.ssh_dir.mkdir(mode=0o700)
        os.chown(self.home, account.pw_uid, account.pw_gid)
        os.chown(self.ssh_dir, account.pw_uid, account.pw_gid)
        self.results.passed("临时账户隔离", f"账户 {self.user} 的 HOME 位于 {self.home}")
        self.results.passed(
            "测试环境",
            f"machine={command_text(['uname', '-m']).strip()}; {command_text(['dbclient', '-V']).strip()}",
        )

    def quality_checks(self) -> None:
        self.results.progress("执行静态脚本和 JSON 配置检查")
        shellcheck = command_text(["shellcheck", "-s", "sh", str(RUN_SOCKS), str(RUN_TUNNEL)])
        if shellcheck.strip():
            raise TestFailure(f"shellcheck 输出异常: {shellcheck}")
        self.results.passed("shellcheck", "bin/run-socks 与 bin/run-tunnel 均无诊断")
        try:
            json.loads(XRAY_FRAGMENT.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise TestFailure(f"xray-fragment.json 不是有效 JSON: {exc}") from exc
        self.results.passed("JSON 解析", "config/xray-fragment.json 可由 Python json 解析")

    def configure(self) -> None:
        self.results.progress("生成临时 SSH 密钥、配置和随机回环端口")
        used: set[int] = set()
        self.ports = {
            "jp": random_loopback_port(used),
            "remote": random_loopback_port(used),
            "socks": random_loopback_port(used),
            "http": random_loopback_port(used),
        }
        account = pwd.getpwnam(self.user)
        self.ssh_dir.mkdir(exist_ok=True)
        client_key = self.ssh_dir / "id_dropbear"
        authorized_keys = self.ssh_dir / "authorized_keys"
        host_key = self.root / "ssh_host_ed25519_key"
        wrong_key = self.root / "wrong_ssh_host_ed25519_key"
        # run-tunnel passes this key to dbclient, so it must use the native
        # Dropbear format generated by the project's installer, not an
        # OpenSSH private-key container.
        client_key_output = command_text(["dropbearkey", "-t", "ed25519", "-f", str(client_key)])
        command_text(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(host_key)])
        command_text(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(wrong_key)])
        client_public = next(
            (line.strip() for line in client_key_output.splitlines() if line.startswith("ssh-")),
            "",
        )
        if not client_public:
            raise TestFailure("dropbearkey 未输出可用于 authorized_keys 的公钥")
        authorized_keys.write_text(client_public + "\n", encoding="utf-8")
        # Dropbear's known_hosts parser treats all data after the algorithm as
        # base64, unlike OpenSSH's optional trailing comment convention.
        # Preserve only the algorithm and keyblob from ssh-keygen output.
        host_public = " ".join(command_text(["ssh-keygen", "-y", "-f", str(host_key)]).split()[:2])
        wrong_public = " ".join(command_text(["ssh-keygen", "-y", "-f", str(wrong_key)]).split()[:2])
        if not host_public or not wrong_public:
            raise TestFailure("ssh-keygen 未输出临时主机公钥")
        # dbclient 2022.83 matches its known_hosts entry by host name rather
        # than OpenSSH's bracketed host:port form, including for -p ports.
        good_line = f"127.0.0.1 {host_public}\n"
        self.good_known_hosts.write_text(good_line, encoding="utf-8")
        (self.ssh_dir / "known_hosts").write_text(good_line, encoding="utf-8")
        (self.root / "wrong_known_hosts").write_text(
            f"127.0.0.1 {wrong_public}\n", encoding="utf-8"
        )

        sshd_config = self.root / "sshd_config"
        sshd_config.write_text(
            "\n".join(
                [
                    f"Port {self.ports['jp']}",
                    "ListenAddress 127.0.0.1",
                    f"HostKey {host_key}",
                    f"PidFile {self.home / 'sshd.pid'}",
                    f"AuthorizedKeysFile {authorized_keys}",
                    "UsePAM no",
                    "PermitRootLogin no",
                    "PasswordAuthentication no",
                    "KbdInteractiveAuthentication no",
                    "PubkeyAuthentication yes",
                    f"AllowUsers {self.user}",
                    "AllowTcpForwarding remote",
                    "PermitOpen none",
                    f"PermitListen 127.0.0.1:{self.ports['remote']}",
                    "GatewayPorts no",
                    "MaxSessions 0",
                    "X11Forwarding no",
                    "AllowAgentForwarding no",
                    "AllowStreamLocalForwarding no",
                    "PermitTTY no",
                    "PermitTunnel no",
                    "LogLevel VERBOSE",
                    "StrictModes yes",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        conf_lines = [
            "JP_HOST='127.0.0.1'",
            f"JP_PORT='{self.ports['jp']}'",
            f"JP_USER='{self.user}'",
            f"REMOTE_PORT='{self.ports['remote']}'",
            f"SOCKS_PORT='{self.ports['socks']}'",
            "SOCKS_USER='egress'",
            f"SOCKS_PASS='{self.password}'",
            "SSH_WINDOW='32768'",
            "SSH_KEEPALIVE='20'",
            "",
        ]
        self.conf.write_text("\n".join(conf_lines), encoding="utf-8")

        for path, mode in (
            (client_key, 0o600),
            (self.ssh_dir / "known_hosts", 0o600),
            (self.good_known_hosts, 0o600),
            (authorized_keys, 0o600),
            (host_key, 0o600),
            (self.conf, 0o600),
        ):
            os.chmod(path, mode)
            os.chown(path, account.pw_uid, account.pw_gid)
        for pub in self.ssh_dir.glob("*.pub"):
            os.chown(pub, account.pw_uid, account.pw_gid)

        # Running this high-port, temporary daemon as the temporary account
        # avoids Ubuntu's root-daemon /run/sshd prerequisite.  The test must
        # not create or otherwise alter that system runtime directory.
        output = command_text(
            [
                "runuser",
                "-u",
                self.user,
                "--",
                "env",
                f"HOME={self.home}",
                "/usr/sbin/sshd",
                "-t",
                "-f",
                str(sshd_config),
            ]
        )
        if output.strip():
            raise TestFailure(f"临时 sshd -t 产生输出: {output}")
        self.results.passed(
            "临时 sshd -t",
            "UsePAM no、PermitListen=127.0.0.1:REMOTE、GatewayPorts no、MaxSessions 0、AllowTcpForwarding remote、PermitOpen none 均被接受",
        )

    def start_process(self, name: str, command: list[str]) -> ManagedProcess:
        log = self.logs_dir / f"{name}.log"
        log_handle = log.open("w", encoding="utf-8")
        try:
            popen = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
        finally:
            log_handle.close()
        process = ManagedProcess(name=name, popen=popen, log=log)
        self.processes.append(process)
        return process

    @staticmethod
    def process_log(process: ManagedProcess, limit: int = 2000) -> str:
        try:
            content = process.log.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            return ""
        return content[-limit:]

    def terminate(self, process: ManagedProcess | None) -> None:
        if process is None or process.popen.poll() is not None:
            return
        try:
            os.killpg(process.popen.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.popen.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.popen.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.popen.wait(timeout=5)

    def wait_for(self, description: str, predicate: Callable[[], bool], process: ManagedProcess | None = None) -> None:
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if process is not None and process.popen.poll() is not None:
                raise TestFailure(
                    f"{description} 前进程意外退出 ({process.popen.returncode}): {self.process_log(process)}"
                )
            if predicate():
                return
            time.sleep(0.1)
        raise TestFailure(f"超时等待: {description}")

    @staticmethod
    def can_connect(port: int) -> bool:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            return False

    def start_services(self) -> None:
        self.results.progress("启动临时 HTTP fixture、OpenSSH、microsocks 与反向隧道")
        self.httpd = ThreadingHTTPServer(("127.0.0.1", self.ports["http"]), FixtureHandler)
        self.http_thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.http_thread.start()
        # microsocks resolves the SOCKS5 hostname itself.  Many systems return
        # ::1 for localhost first, so serve the identical fixture on both
        # loopback families rather than weakening the required hostname test.
        try:
            self.httpd_v6 = ThreadingHTTPServerV6(("::1", self.ports["http"]), FixtureHandler)
        except OSError as exc:
            raise TestFailure(f"无法在临时 IPv6 回环端口启动 localhost fixture: {exc}") from exc
        self.http_thread_v6 = threading.Thread(target=self.httpd_v6.serve_forever, daemon=True)
        self.http_thread_v6.start()
        self.wait_for("HTTP fixture 监听", lambda: self.can_connect(self.ports["http"]))

        sshd = self.start_process(
            "sshd",
            [
                "runuser",
                "-u",
                self.user,
                "--",
                "env",
                f"HOME={self.home}",
                "/usr/sbin/sshd",
                "-D",
                "-e",
                "-f",
                str(self.root / "sshd_config"),
            ],
        )
        self.wait_for("临时 sshd 监听", lambda: self.can_connect(self.ports["jp"]), sshd)

        account_env = [
            f"HOME={self.home}",
            f"PATH={self.bin_dir}:/usr/bin:/bin",
        ]
        socks = self.start_process(
            "socks",
            ["runuser", "-u", self.user, "--", "env", *account_env, str(self.bin_dir / "run-socks"), str(self.conf)],
        )
        self.wait_for("microsocks 监听", lambda: self.can_connect(self.ports["socks"]), socks)
        self.current_tunnel = self.start_tunnel()
        self.results.passed("临时服务启动", "HTTP、临时 sshd、microsocks 和 run-tunnel 均只监听临时回环端口")

    def start_tunnel(self) -> ManagedProcess:
        process = self.start_process(
            "tunnel",
            [
                "runuser",
                "-u",
                self.user,
                "--",
                "env",
                f"HOME={self.home}",
                f"PATH={self.bin_dir}:/usr/bin:/bin",
                str(self.bin_dir / "run-tunnel"),
                str(self.conf),
            ],
        )
        self.wait_for(
            "反向隧道远端回环端口监听",
            lambda: self.can_connect(self.ports["remote"]),
            process,
        )
        return process

    def listener_lines(self, port: int) -> list[str]:
        lines = command_text(["ss", "-ltnH"]).splitlines()
        endpoint = re.compile(rf"(?<!\d){port}(?:\s|$)")
        return [line for line in lines if endpoint.search(line)]

    def test_loopback_listener(self) -> None:
        lines = self.listener_lines(self.ports["remote"])
        if not lines:
            raise TestFailure("ss 未发现 SSH 服务端反向监听端口")
        unexpected = [line for line in lines if f"127.0.0.1:{self.ports['remote']}" not in line]
        if unexpected:
            raise TestFailure(f"反向监听不是仅 IPv4 回环: {unexpected}")
        self.results.passed("服务端反向监听范围", f"ss 显示仅 127.0.0.1:{self.ports['remote']}（未绑定 0.0.0.0 或 *）")

    def test_http_through_socks(self) -> None:
        completed = subprocess.run(
            [
                "curl",
                "--silent",
                "--show-error",
                "--fail",
                "--max-time",
                "12",
                "--socks5-hostname",
                f"127.0.0.1:{self.ports['remote']}",
                "--proxy-user",
                f"egress:{self.password}",
                f"http://localhost:{self.ports['http']}/",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
        )
        if completed.returncode or completed.stdout != "NAT-EGRESS-INTEGRATION-OK\n":
            raise TestFailure(f"curl 经 socks5-hostname 访问 localhost 失败: {completed.stdout.strip()}")
        self.results.passed("TCP 经反向隧道和 SOCKS 域名解析", "curl --socks5-hostname 访问 http://localhost:临时端口 返回 fixture 标记")

    def test_wrong_socks_password(self) -> None:
        sock = socket.create_connection(("127.0.0.1", self.ports["remote"]), timeout=5)
        try:
            sock.settimeout(5)
            sock.sendall(b"\x05\x01\x02")
            if recv_exact(sock, 2) != b"\x05\x02":
                raise TestFailure("错误密码测试前 SOCKS 未要求密码认证")
            user_b = b"egress"
            wrong_b = b"wrong-password"
            sock.sendall(bytes([1, len(user_b)]) + user_b + bytes([len(wrong_b)]) + wrong_b)
            reply = recv_exact(sock, 2)
            if reply == b"\x01\x00":
                raise TestFailure("错误 SOCKS 密码被接受")
        finally:
            sock.close()
        self.results.passed("错误 SOCKS 密码拒绝", "SOCKS5 用户名/密码协商未返回认证成功")

    def test_udp_associate_rejected(self) -> None:
        sock = socks_auth(self.ports["remote"], "egress", self.password)
        try:
            # SOCKS5 UDP ASSOCIATE: VER=5, CMD=3, RSV=0, ATYP=IPv4, 0.0.0.0:0.
            sock.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
            try:
                reply = recv_exact(sock, 2)
            except (ConnectionResetError, BrokenPipeError, socket.timeout):
                reply = b""
            if reply == b"\x05\x00":
                raise TestFailure("UDP ASSOCIATE 被 SOCKS 服务接受")
        finally:
            sock.close()
        self.results.passed("UDP ASSOCIATE 拒绝", "认证后 SOCKS5 CMD=0x03 未获得成功响应")

    def test_wrong_host_key_rejected(self) -> None:
        self.results.progress("替换临时 known_hosts，验证严格主机密钥拒绝")
        self.terminate(self.current_tunnel)
        self.current_tunnel = None
        self.wait_for("旧反向监听关闭", lambda: not self.can_connect(self.ports["remote"]))
        shutil.copy2(self.root / "wrong_known_hosts", self.ssh_dir / "known_hosts")
        os.chmod(self.ssh_dir / "known_hosts", 0o600)
        account = pwd.getpwnam(self.user)
        os.chown(self.ssh_dir / "known_hosts", account.pw_uid, account.pw_gid)
        rejected = self.start_process(
            "wrong-host-key",
            [
                "runuser",
                "-u",
                self.user,
                "--",
                "env",
                f"HOME={self.home}",
                f"PATH={self.bin_dir}:/usr/bin:/bin",
                str(self.bin_dir / "run-tunnel"),
                str(self.conf),
            ],
        )
        try:
            rejected.popen.wait(timeout=10)
        except subprocess.TimeoutExpired as exc:
            self.terminate(rejected)
            raise TestFailure("known_hosts 已替换为错误密钥，但 run-tunnel 未退出") from exc
        if rejected.popen.returncode == 0:
            raise TestFailure("错误日本主机密钥被接受")
        log = self.process_log(rejected)
        if "host key" not in log.lower() and "hostkey" not in log.lower():
            raise TestFailure(f"错误 known_hosts 导致非预期失败，无法确认主机密钥检查: {log}")
        self.results.passed("错误日本主机密钥拒绝", "替换 known_hosts 后 run-tunnel 非零退出，且日志明确为 host key 错误；未使用 -y")

        shutil.copy2(self.good_known_hosts, self.ssh_dir / "known_hosts")
        os.chmod(self.ssh_dir / "known_hosts", 0o600)
        os.chown(self.ssh_dir / "known_hosts", account.pw_uid, account.pw_gid)
        self.current_tunnel = self.start_tunnel()

    def test_forward_failure_exit(self) -> None:
        self.results.progress("占用目标远端端口，验证 ExitOnForwardFailure")
        self.terminate(self.current_tunnel)
        self.current_tunnel = None
        self.wait_for("正常反向监听关闭", lambda: not self.listener_lines(self.ports["remote"]))
        blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        # Permit rebinding after prior curl connections have entered TIME_WAIT;
        # the preceding ss check guarantees no forwarding listener remains.
        blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        blocker.bind(("127.0.0.1", self.ports["remote"]))
        blocker.listen(1)
        try:
            conflicted = self.start_process(
                "forward-conflict",
                [
                    "runuser",
                    "-u",
                    self.user,
                    "--",
                    "env",
                    f"HOME={self.home}",
                    f"PATH={self.bin_dir}:/usr/bin:/bin",
                    str(self.bin_dir / "run-tunnel"),
                    str(self.conf),
                ],
            )
            try:
                conflicted.popen.wait(timeout=10)
            except subprocess.TimeoutExpired as exc:
                self.terminate(conflicted)
                raise TestFailure(
                    "端口冲突时 run-tunnel 未在 10 秒内退出；当前 Dropbear 已声明支持 ExitOnForwardFailure"
                ) from exc
            if conflicted.popen.returncode == 0:
                raise TestFailure("端口冲突时 run-tunnel 意外以零状态退出")
            log = self.process_log(conflicted)
            if not re.search(r"forward|bind|listen", log, flags=re.IGNORECASE):
                raise TestFailure(f"端口冲突产生非预期错误，无法确认转发失败: {log}")
        finally:
            blocker.close()
        self.results.passed("端口冲突的 ExitOnForwardFailure", "占用 PermitListen 目标端口后 run-tunnel 非零退出，不会静默保持连接")

    def cleanup(self) -> None:
        self.results.progress("清理临时进程、测试账户和目录")
        for process in reversed(self.processes):
            self.terminate(process)
        # The account is unique to this run, so this only touches processes the
        # test itself could have created.  It also handles grandchildren after a
        # failed wrapper start.
        if self.created_user:
            subprocess.run(["pkill", "-KILL", "-u", self.user], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["userdel", "--remove", self.user], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.created_user = False
        if self.httpd is not None:
            self.httpd.shutdown()
            self.httpd.server_close()
        if self.http_thread is not None:
            self.http_thread.join(timeout=3)
        if self.httpd_v6 is not None:
            self.httpd_v6.shutdown()
            self.httpd_v6.server_close()
        if self.http_thread_v6 is not None:
            self.http_thread_v6.join(timeout=3)
        if self.keep_logs:
            self.results.progress(f"保留临时日志目录: {self.root}")
        else:
            shutil.rmtree(self.root, ignore_errors=True)

    def run(self) -> None:
        self.setup_binaries_and_account()
        self.quality_checks()
        self.configure()
        self.start_services()
        self.test_loopback_listener()
        self.test_http_through_socks()
        self.test_wrong_socks_password()
        self.test_udp_associate_rejected()
        self.test_wrong_host_key_rejected()
        self.test_forward_failure_exit()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep-logs", action="store_true", help="失败排障时保留 /tmp 下临时目录（默认仍会清理）")
    args = parser.parse_args()
    if os.geteuid() != 0:
        # useradd and an isolated sshd privilege separation setup need root; sudo
        # only re-executes this test and never invokes the system ssh service.
        os.execvp("sudo", ["sudo", "-E", sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])

    suite = IsolatedIntegration(keep_logs=args.keep_logs)
    outcome = "PASS"
    error = ""
    try:
        suite.run()
    except (TestFailure, subprocess.SubprocessError, OSError, socket.error) as exc:
        outcome = "FAIL"
        error = str(exc)
        suite.results.failed("集成测试执行", error)
    finally:
        suite.cleanup()

    print("\n[integration] machine-readable summary:")
    print(json.dumps({"outcome": outcome, "error": error, "results": suite.results.rows}, ensure_ascii=False, indent=2))
    return 0 if outcome == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
