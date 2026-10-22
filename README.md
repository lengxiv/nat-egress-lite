# NAT Egress Lite — 交互式一键部署

在 **Debian 13 / ARM64 NAT 落地机**上以 root 执行一个脚本，填写日本 VPS 的 SSH 登录信息。脚本自动选端口、创建凭据、通过 SSH 配置日本端、对接现有原生 Xray，最后启动落地服务。落地侧只常驻 Dropbear 客户端和 microsocks，面向 64 MB 内存、1 GB 磁盘的个人低并发场景；不需要 Docker、Python 常驻服务或落地公网端口映射。

## 直接使用

下载仓库中的 **`oneclick.sh`**，上传到 NAT 落地机，然后运行：

```bash
bash oneclick.sh
```

该文件已经包含所需配置和代码，**不需要在落地机安装 Git、克隆整个仓库或编译源码**。仓库是私有的，未登录的 `curl raw.githubusercontent.com/...` 无法直接下载，请从 GitHub 登录页面或交付附件取得脚本。

如果已经下载完整项目，也可以用原命令，它现在会进入同一个交互向导：

```sh
sh install-debian.sh
```

脚本会询问日本公网 IP/域名、SSH 端口及管理员用户名；可以使用密码，或填写现有 Dropbear 格式的管理员私钥路径。**密码在 SSH 提示中现场输入，不写进脚本，不需要提交到聊天或仓库。** 日本管理员必须是 root，或者具有免密 sudo。首次连接会显示主机指纹，你需要通过可信的日本 VPS 控制台核对后确认，脚本不会跳过验证。

随后按提示回车即可使用自动端口与自动 Xray 识别。检测有歧义时，会显示候选并让你输入配置路径或入站 tag，而不是擅自修改错误入口。

## 自动完成哪些事情

落地端检测 Debian 版本、CPU 架构、systemd 和实际已监听的 TCP 端口。优先选择空闲的 SOCKS 端口；端口冲突时拒绝占用其他程序的端口，并提示重新输入。生成独立落地密钥与随机 SOCKS 密码，创建低权限账户和 systemd 服务。

日本端读取实际监听情况，选择空闲的反向 TCP 端口，或者使用你指定的端口。自动添加专用受限隧道账户、公钥和回环转发限制，检查有效 sshd 配置后重载。**不改现有管理 SSH 监听端口，不改全局登录认证，不开放公网 SOCKS，也不擅自修改防火墙。**

对于原生 `xray.service` 的单文件 JSON 配置，自动识别配置路径和唯一合适的入站 tag。多个配置或入口时让你选择。合并 SOCKS 出站与该入口的 TCP 路由，阻断该入口的 UDP；保留其他入站、原出站顺序和安全阻断规则。修改前备份，Xray 校验通过后再替换配置和重载；失败时恢复旧配置。重新运行不重复添加项目规则。

运行完成会显示两端实际端口。你原来的 Xray 客户端连接方式不变，指定入口的 TCP 流量改由 NAT 落地出网。

## 端口识别的边界

**落地 SOCKS 端口和日本反向端口会自动检测本机占用，并可交互输入。** 日本管理 SSH 的公网端口无法在尚未登录时从落地机可靠读取，所以由你填写，默认 22；它不是 VLESS/REALITY 等 Xray 客户端入口端口。如果日本本身有端口映射，需要填写实际公网可访问的 SSH 端口。

检测到“本机监听”不等于商家安全组、防火墙或 NAT 映射已经允许访问。此方案由落地端主动连接日本已有 SSH 端口，因此不要求落地公网映射端口，也不依赖 TUN。

## 支持范围

```text
客户端 → 日本现有 Xray 入站 → 加密 SSH 反向隧道 → NAT 落地 microsocks → 互联网
```

**只支持 TCP，不支持 UDP。** microsocks 上游仅支持 SOCKS5 TCP CONNECT。[1] 所选入口的 UDP 会被阻断，不会悄悄从日本直连出口绕过；游戏、实时语音或必须使用 UDP 的应用不适合此版本。若未来确认有内核 WireGuard 网络管理权限且出站 UDP 可用，完整 TCP+UDP 落地优先评估 WireGuard，见 `docs/wireguard.md`。[2]

日本端自动合并仅针对原生 systemd Xray 的单文件 JSON。3x-ui 等面板数据库管理、Docker 独立网络、拆分配置或 JSONC 注释配置不能承诺自动支持，脚本会停止并说明问题，而不是盲目覆盖。你也可明确选择不修改 Xray，此时只生成 `/etc/nat-egress-jp/xray-fragment.json`，并提示入口尚未完成对接。

SOCKS 两端只监听回环，SSH 使用主机验证和独立受限账户。[3] [4] 自动修改 Xray 仅影响所选入站；Xray 系统 DNS、客户端绕过代理流量和 IPv6 出口需按原配置另行确认，不能仅凭网页出口 IP 保证没有 DNS 泄漏。[5]

不能保证整个 Debian 系统在 64 MB 内存下长期稳定。安装时的 apt、基础系统服务、socket 缓冲和连接数量都可能造成 OOM。服务保留文件描述符与内存保护限制，但这些上限不是实际内存占用，也不替代你的真实 NAT 机器压测。SSH 多流复用同一个 TCP 隧道，不适合高并发、高吞吐或低时延游戏。

## 查看与停止

```sh
systemctl status nat-egress-socks nat-egress-tunnel --no-pager
journalctl -u nat-egress-tunnel -n 30 --no-pager
systemctl disable --now nat-egress-tunnel nat-egress-socks
```

脚本完成后的 `active` 只是进程状态，不能代替真实客户端出口验证。落地配置位于 `/etc/nat-egress/egress.conf`，私钥只保存在落地机；不要上传这两个文件或备份到仓库。升级 Debian 安全软件包后可重启项目服务。

## 开发与测试

`oneclick.sh` 是可独立运行的发布脚本；修改源码后在开发机执行 `python3 build-oneclick.py` 重建。源流程位于 `scripts/setup-head.sh`，日本端配置位于 `scripts/setup-jp.sh`，Xray 合并逻辑位于 `scripts/xray_merge.py`。Python 只用于开发与日本端的配置处理，不在 64 MB 落地端安装。

端口识别和 Xray 合并有独立测试；`tests/integration.py` 是此前反向 SSH 数据路径的隔离开发测试。实际测试范围见 `docs/test-results.md`。目前没有连接或部署到用户的真实服务器。

## References

[1]: https://github.com/rofl0r/microsocks "MicroSocks upstream README"
[2]: https://www.wireguard.com/quickstart/ "WireGuard Quick Start"
[3]: https://manpages.debian.org/trixie/dropbear-bin/dbclient.1.en.html "Debian 13 dbclient manual"
[4]: https://man.openbsd.org/sshd_config "OpenSSH server configuration manual"
[5]: https://xtls.github.io/en/config/routing.html "Xray routing documentation"
