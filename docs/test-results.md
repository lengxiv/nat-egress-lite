# 实际测试结果

2026-10-23，最终隔离集成测试 `sudo python3 tests/integration.py` 返回退出码 0，汇总 `outcome: PASS`。测试环境为 Ubuntu 24.04.5 LTS、aarch64；不是用户的 Debian 13 NAT 容器，也没有施加整机 64 MB 内存/1 GB 磁盘限制。

## 已通过的检查

ShellCheck 检查两个启动脚本通过；主代理另行检查安装器与 probe 同样通过。Xray 片段可由 Python JSON 解析。临时 OpenSSH 配置 `sshd -t` 通过，包含 `AllowTcpForwarding remote`、指定回环 `PermitListen`、`PermitOpen none`、`GatewayPorts no` 和 `MaxSessions 0`。

临时服务启动成功。通过 `ss` 确认 SSH 远程监听只有 `127.0.0.1:随机端口`，未绑定公网通配地址。使用 `curl --socks5-hostname` 经 SSH 反向端口访问 HTTP fixture 的 `localhost` 域名目标，返回预期响应。测试在 IPv4 和 IPv6 回环上提供相同 fixture，以覆盖解析优先返回 `::1` 的环境。

正确 SOCKS 凭据成功。错误密码被拒绝。SOCKS5 `UDP ASSOCIATE` 被拒绝。替换成错误的日本主机公钥后隧道非零退出，日志明确是 host key mismatch；没有使用 `-y`。占用远程监听端口后，`ExitOnForwardFailure` 使隧道非零退出，而不是静默在线。

临时目录、账户与进程均在 finally 中清理；没有部署、改变系统 sshd 配置或连接用户的真实服务器。

## Xray 配置校验

主代理从 XTLS/Xray-core 官方发布包取得 Xray 26.10.21、linux/arm64，给项目合并片段添加临时回环 SOCKS 入站后执行 `xray run -test -config /tmp/nat-xray-check/validation.json`，返回 `Configuration OK`。这证明该版本接受模板语法，不代表测试了用户当前 Xray 版本、现有规则合并或真实客户端流量。

## Dropbear 版本兼容边界

沙盒已安装 Dropbear 2022.83，较 Debian 13 的 2025.89 旧。2022.83 会忽略 `BatchMode`、`PasswordAuthentication` 与 `StrictHostKeyChecking` 选项；此次测试中错误密钥拒绝依靠其既有 known_hosts 匹配行为。**不能据此宣称旧版具备本项目要求的完整无人值守严格认证语义。安装器仅面向 Debian 13；不应直接套用到 Ubuntu 旧 Dropbear 或更老版本。** Debian 13 dbclient 手册与 Dropbear 2025.89 的 cli-runopts.c 已核实这些选项受到支持。[1] [2]

原生 Dropbear 私钥由 `dropbearkey` 生成，不把 OpenSSH 私钥容器直接作为 `id_dropbear` 使用。known_hosts 的纯主机名/IP + 算法 + Base64 三字段格式已通过此次测试；Dropbear 2025.89 的官方 cli-kex.c 同样按纯 remotehost 名称匹配，README 已据此修正。[3]

## 未验证的事项

未测试 Debian 13 发行版软件包在用户 NAT 机器的真实运行、systemd 服务沙箱和 cgroup 限制是否被商家允许、WireGuard/CAP_NET_ADMIN、出站 UDP、实际公网出口和 DNS 行为。没有进行吞吐压测、64 MB 整机压测、OOM 恢复或长期稳定性测试，也没有验证完整 WireGuard UDP 出口方案。

开发测试需要编译 microsocks 并安装 Python、OpenSSH、curl 等测试依赖，只在资源充足的隔离开发机运行；64 MB 落地部署不需要这些工具，安装器使用现成 Debian 包。

## References

[1]: https://manpages.debian.org/trixie/dropbear-bin/dbclient.1.en.html "Debian 13 dbclient manual"
[2]: https://raw.githubusercontent.com/mkj/dropbear/DROPBEAR_2025.89/src/cli-runopts.c "Dropbear 2025.89 client option implementation"
[3]: https://raw.githubusercontent.com/mkj/dropbear/DROPBEAR_2025.89/src/cli-kex.c "Dropbear 2025.89 host key verification implementation"
