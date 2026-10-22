# NAT Egress Lite

针对 **Debian 13 / ARM64 / 64 MB RAM / 1 GB 磁盘 NAT 落地机**的轻量部署项目。日本 VPS 保留现有 Xray 入站，落地机只运行 Debian 官方的 microsocks 与 Dropbear SSH 客户端。没有面板、Docker、Go/Python 常驻程序或数据库；安装时不在落地机编译源码。

**推荐原则：有内核 WireGuard 网络权限且出站 UDP 可用时优先 WireGuard；这些条件尚未确认时，本项目交付 SSH 反向隧道 + SOCKS5 的 TCP 备用实现。** 新内核版本不代表 NAT 容器允许创建网络接口。内核 WireGuard 不依赖 `/dev/net/tun`，NAT 端也不必有公网入站端口。[1]

这是部署和集成项目，不是自创加密协议。没有取得你的服务器连接凭据，因此尚未部署到真实日本 VPS 或 NAT 落地机。

## 流量走向与协议

```text
客户端
  │ 你现有的 Xray 入站协议（例如 VLESS + REALITY）
  ▼
日本 VPS：Xray
  │ SOCKS5 → 127.0.0.1:19080
  │ 日本 sshd 上的反向监听（只允许本机连接）
  │ 加密 SSH 隧道：由 NAT 落地机主动连接日本 VPS
  ▼
NAT 落地机：Dropbear 客户端
  │ 127.0.0.1:1080
  ▼
microsocks → 目标互联网服务器
```

SSH 负责日本 VPS 与落地机之间的加密、主机认证和反向端口转发。SOCKS5 负责在落地机发起目标 TCP 连接。目标网站看到落地机的实际出网地址；NAT 机器通常呈现供应商共享的公网出口，而非独享公网 IP。IPv6 若可用且目标被解析为 IPv6，会呈现落地侧 IPv6，不能据此承诺固定 IPv4。

**此实现不支持 UDP。** microsocks 官方只有 SOCKS5 TCP CONNECT，不支持 UDP ASSOCIATE。[2] QUIC、游戏和实时语音 UDP 不能走它；网页通常可在 QUIC 被拒绝后改用 TCP，但不能保证所有应用都回退。SSH 多流共享一个 TCP 连接，丢包时可能出现队头阻塞，不适合高吞吐或低时延游戏。不要开启额外 mux，也不要让失败的落地出站自动回退日本直连。

## 64 MB / 1 GB 的部署取舍

现有 Debian 系统可以先保留，不建议仅为这个项目立即重装。若以后可选镜像，最小化 Alpine 值得评估，但本安装器只支持 Debian 13 + systemd。

不能承诺固定内存占用或 64 MB 下永不 OOM。系统基础服务、容器内存计费、socket 缓冲、并发线程都会影响峰值。服务设置了文件描述符上限 64；这不是“64 个连接”的保证。microsocks 的 `TasksMax=40` 与两项服务的 `MemoryMax=16M/20M` 是单服务保护上限，不是实际用量，也不是让整个系统只用 36 MB。cgroup 支持不足的 NAT 容器可能无法执行这些限制。

从个人低并发开始，观察 `free -m`、`systemctl status` 里的 Memory 与重启计数。不要在落地端运行 Xray 面板、Docker、编译器和大型规则库。缓存及日志应受控；不要为了“省内存”盲目停用关键系统或 SSH 服务。1 GB 是否够用以 `df -h /` 为准，内核版本也可能来自宿主机，不能拿它推断根盘占用。swap/zram 不是低资源容器必然支持的功能，也不代替实测。

## 1. 落地机安装但先不启动

将项目解压到落地机，进入目录，以 root 执行：

```sh
sh bin/probe
sh install-debian.sh
```

安装器只从 Debian 官方仓库安装 `microsocks` 和 `dropbear-bin`，自动匹配 ARM64，不安装 Dropbear 服务端，不改现有 SSH。它创建 `nat-egress` 非登录账户及独立服务，并在落地机现场生成 Ed25519 私钥。服务不会自动启动。

先确认有足够余量做 `apt-get update/install`；这些步骤在极低内存环境也可能失败。若失败，先诊断 apt 输出与 OOM，不要直接改用未知来源的一键脚本或不核验的二进制。请确保更新 Debian 的安全软件包。

生成的公钥可以从这里重新读取：

```sh
runuser -u nat-egress -- dropbearkey -y \
  -f /var/lib/nat-egress/.ssh/id_dropbear | sed -n '/^ssh-/p'
```

仅复制输出的 `ssh-ed25519 ...` 公钥行到日本 VPS。**私钥只留在落地机，不上传仓库、不发聊天、不复制到日本 VPS。**

编辑 `/etc/nat-egress/egress.conf`：

```sh
JP_HOST='你的日本VPS公网IP或域名'
JP_PORT='22'
JP_USER='nat-tunnel'
REMOTE_PORT='19080'
SOCKS_PORT='1080'
SOCKS_USER='egress'
SOCKS_PASS='你现场生成的随机密码'
SSH_WINDOW='32768'
SSH_KEEPALIVE='20'
```

推荐在服务器现场用 `od -An -N24 -tx1 /dev/urandom | tr -d ' \n'` 生成密码。不要使用示例占位密码。保持配置权限 `root:nat-egress 0640`。该配置是可信 shell 文件，不能让陌生人编辑。microsocks 上游会清空用户名密码对应的 argv 内容，但不要依赖这一点保护多用户机器的瞬时进程信息。[2]

## 2. 日本 VPS 建立专用隧道账户

日本 VPS 应有可从落地端访问的 OpenSSH TCP 端口。可以复用现有 SSH 端口，不要求落地端有公网端口或 TUN。

以下命令仅在 `nat-tunnel` 账户不存在时执行，**不要复用管理账户**：

```sh
useradd --system --user-group --create-home \
  --home-dir /var/lib/nat-tunnel --shell /usr/sbin/nologin \
  --password '*' nat-tunnel
install -d -o nat-tunnel -g nat-tunnel -m 0700 /var/lib/nat-tunnel/.ssh
```

`'*'` 不是可用密码；该账户仍应只有公钥认证。某些发行版/PAM 有额外账户策略，需要管理员核验。写入 `/var/lib/nat-tunnel/.ssh/authorized_keys`，只放置实际落地公钥，完整一行格式：

```text
restrict,port-forwarding,permitlisten="127.0.0.1:19080" ssh-ed25519 替换为落地公钥内容 nat-egress
```

设为 `nat-tunnel:nat-tunnel 0600`。复制项目 `deploy/sshd-nat-egress.conf` 到 `/etc/ssh/sshd_config.d/60-nat-egress.conf`。确认主 `/etc/ssh/sshd_config` 确实 Include 这个目录；若有较早的 Match/global 设置，应检查最终生效值，不能只看文件内容。[3]

`MaxSessions 0` 禁止 shell/exec/subsystem 会话，但允许端口转发。`PermitListen` 仅授权日本本机 19080 监听，`AllowTcpForwarding remote` 禁止把该账户变成任意正向代理。[3]

**保留当前管理 SSH 会话，不改管理端口和全局认证。** 先在日本 VPS 检查：

```sh
/usr/sbin/sshd -t
/usr/sbin/sshd -T -C user=nat-tunnel,host=nat-client,addr=落地侧实际源IP \
  | grep -E 'allowtcpforwarding|permitlisten|permitopen|gatewayports|maxsessions|passwordauthentication'
```

应该看到 `remote`、`127.0.0.1:19080`、`none`、`no`、`0` 及密码认证 `no`。确认无误后再 `systemctl reload ssh`。别直接重启一个未经检查的 sshd。如果端口不是 19080，需要同步修改 key 的 permitlisten、sshd 片段、落地配置与 Xray 出站。

不必在防火墙或商家安全组开放 1080 / 19080。只放行已有客户端入口端口和落地→日本 SSH 所用端口；若落地源公网 IP 固定，可以进一步对 SSH 做源地址限流/授权，但不要误封管理连接。

## 3. 固定日本 VPS 主机公钥

本项目强制 `StrictHostKeyChecking=yes`，不使用自动接受陌生主机的 `-y`。[4] 在**可信的日本 VPS 控制台或已核验 SSH 会话**中执行：

```sh
cat /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

把主机公钥的算法与 Base64 内容写入落地机 `/var/lib/nat-egress/.ssh/known_hosts`。主机字段必须和 `JP_HOST` 一致，只保留三个字段，行尾不附加注释。Dropbear 2025.89 按主机名匹配，而不是 OpenSSH 的端口编码格式。[8]

```text
日本IP或域名 ssh-ed25519 替换为日本主机公钥内容
```

**即使 SSH 不是 22 端口，本项目的 Dropbear known_hosts 仍使用上面的纯主机名/IP，不写 `[host]:port`。** 端口通过 `JP_PORT` 与客户端 `-p` 指定。如果同一 IP 的不同端口属于不同服务器且主机密钥不同，给它们配置不同域名，不要合并到同一主机名条目。

```sh
chown nat-egress:nat-egress /var/lib/nat-egress/.ssh/known_hosts
chmod 0600 /var/lib/nat-egress/.ssh/known_hosts
```

不能把未独立核验的 `ssh-keyscan` 结果当作可信主机身份。更换主机密钥后应通过可信渠道重新核验，不应关闭检查。

## 4. 启动落地服务，先验证隧道

```sh
systemctl enable --now nat-egress-socks nat-egress-tunnel
systemctl status nat-egress-socks nat-egress-tunnel --no-pager
journalctl -u nat-egress-tunnel -n 30 --no-pager
```

隧道失联时 systemd 每 10 秒重试；SSH keepalive 用于识别失效连接和维持 NAT TCP 状态。[4] 若远程端口已占用，`ExitOnForwardFailure` 让隧道退出而不是“看似在线却不能转发”。这不等于应用层健康检查：SOCKS 仍需 curl 验证。

在日本 VPS 上先确认监听只在回环：

```sh
ss -ltnp | grep ':19080'
```

应为 `127.0.0.1:19080`，不是 `0.0.0.0`。通过本机 SOCKS 验证时可使用：

```sh
curl --max-time 20 --socks5-hostname 127.0.0.1:19080 \
  --proxy-user 'egress:实际密码' https://api.ipify.org
```

上述测试的密码会短暂出现于 curl 命令行/历史，私有管理员测试可接受时再执行；多用户环境请用权限 0600 的 curl 配置文件传凭据。应返回落地侧公网出口。不要为了诊断把 SOCKS 监听改成公网开放。

## 5. 对接日本 VPS 的 Xray

`config/xray-fragment.json` 是**合并片段，不是完整 Xray 配置**。保留你现有 inbounds、证书/REALITY 和管理配置，仅追加出站与针对指定入站的路由。没有足够信息替你选择或改动当前对外入站协议。

1. 把片段两个 outbounds 加入现有 outbounds 数组；若 tag 已存在，不要重复添加。
2. 把密码改成落地配置中的同一密码。
3. 把两条规则里的 `REPLACE_WITH_EXISTING_INBOUND_TAG` 改成实际 Xray 入站 tag。
4. 将这两条规则置于针对该入口的已有兜底/直连规则之前。UDP 先阻断，TCP 固定指向 `nat-egress`。若有现有的安全阻断规则，保留它们在适当的前面位置。
5. 备份现有配置，在日本 VPS 运行 `xray run -test -config /你的/完整/config.json`，通过后按你原来的服务/面板机制重载。

模板使用传统 `settings.servers[].users[]` 写法以兼容既有 Xray；当前官方源码仍接受此格式。新版本文档展示的 `settings.address/port/user/pass` 扁平写法也是另一种写法，不能混搭。[5] [6]

Xray 路由按顺序匹配，无规则命中时会使用首个出站；因此 tag 和规则顺序必须正确。[7] 本项目不提供自动回退日本直连的 balancer。**本片段只约束匹配入站的代理 TCP/UDP，不能保证 Xray 内置 DNS、系统 DNS 或应用绕过代理流量的出口。**

如果请求保留为域名并经 SOCKS5 传给落地，解析由 microsocks 在落地执行。若客户端或 Xray 提前解析了域名，DNS 可能已在客户端/日本完成，必须单独审查现有 DNS、sniffing 和 `domainStrategy` 配置，不能只凭出口 IP 判定没有 DNS 泄漏。UDP DNS 被阻断后，需要客户端使用适当的 TCP DNS/DoH 路径；它必须同样被代理规则覆盖。

日本 Xray 若在 Docker 内，容器的 `127.0.0.1` **不等于宿主机回环**。本方案默认 Xray 与 sshd 同宿主机网络命名空间；容器部署应先确认 host 网络或采用受控桥接。不要直接把 19080 暴露公网解决容器问题。

## 常见错误与维护

`Host key ...`：核对 JP_HOST、端口、known_hosts 主机字段和主机公钥。不关闭验证。`Permission denied`：查日本 `/var/log/auth.log` 或 ssh 服务日志，核对实际家目录、账户策略、authorized_keys 及文件权限。`Remote port forwarding failed`：核对有效 PermitListen、key 限制和端口冲突。启动失败而 SOCKS 没日志：SOCKS 服务默认丢弃访问日志以节省磁盘，用 `systemctl status` 或暂时以前台方式诊断，避免常驻写大量访问日志。

停止：`systemctl disable --now nat-egress-tunnel nat-egress-socks`。升级：通过 Debian 安全仓库更新 `dropbear-bin` 与 `microsocks`，再重启这两个服务。无需升级项目附带测试源码来维护实际安装的发行版软件包。

64 MB 出现 OOM、频繁重启或 TLS 请求超时时，先降低并发并检查基础系统资源；不要为跑满带宽放大 SSH 窗口。项目只适合小规模低并发使用，服务器网络与出口限制仍由供应商决定。用于你有权管理的设备和合规网络访问。

## 验证与源码

`tests/integration.py` 在隔离沙盒内启动临时 OpenSSH 服务、Dropbear 和 microsocks，验证回环反向 TCP、认证、域名目标、UDP 拒绝、错误主机密钥拒绝及端口限制。运行需要 root，仅用于开发沙盒，不在 64 MB 落地机执行。`docs/test-results.md` 记录实际测试范围；它不等于 Debian ARM64 真机压测。

`vendor/microsocks` 保存 MIT 上游源码，参考提交见 `docs/sources.md`，**仅供开发测试**。安装器从 Debian 官方仓库安装现成包；项目不附带错误架构的 x86_64 可执行文件。WireGuard 的条件、探测及未完成的 UDP 集成边界见 `docs/wireguard.md`。

## References

[1]: https://www.wireguard.com/quickstart/ "WireGuard Quick Start"
[2]: https://github.com/rofl0r/microsocks "MicroSocks upstream README and source"
[3]: https://man.openbsd.org/sshd_config "OpenSSH server configuration manual"
[4]: https://manpages.debian.org/trixie/dropbear-bin/dbclient.1.en.html "Debian 13 Dropbear client manual"
[5]: https://raw.githubusercontent.com/XTLS/Xray-core/main/infra/conf/socks.go "Xray SOCKS JSON configuration implementation"
[6]: https://xtls.github.io/en/config/outbounds/socks.html "Xray SOCKS outbound documentation"
[7]: https://xtls.github.io/en/config/routing.html "Xray routing documentation"
[8]: https://raw.githubusercontent.com/mkj/dropbear/DROPBEAR_2025.89/src/cli-kex.c "Dropbear 2025.89 host key verification implementation"
