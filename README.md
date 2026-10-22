# NAT Egress Lite — 通用 Linux 落地一键部署

这是可重复使用的 Linux 落地项目，**不绑定某一台 VPS，不限定 Debian 13/ARM64，也不限定日本入口**。你在准备作为落地的服务器上运行同一条命令，脚本检测系统、架构、服务管理器与端口，入口地址和 SSH 端口由交互输入。

## 一键命令

在落地机以 root 执行：

```sh
curl -fsSL https://raw.githubusercontent.com/lengxiv/nat-egress-lite/main/install.sh -o "$HOME/nat-egress-install.sh" && sh "$HOME/nat-egress-install.sh"
```

只有 wget 时：

```sh
wget -O "$HOME/nat-egress-install.sh" https://raw.githubusercontent.com/lengxiv/nat-egress-lite/main/install.sh && sh "$HOME/nat-egress-install.sh"
```

入口 `install.sh` 是 POSIX shell，可在缺少 Bash 的 Alpine 上先通过系统仓库补齐 Bash，再启动完整向导。公共仓库不需要 GitHub Token。部署端不安装 Git、不克隆源码、不安装编译器。

也可直接下载独立 `oneclick.sh` 后执行 `bash oneclick.sh`；完整源码包中的 `sh install-debian.sh` 仅保留旧命令兼容，已不限制 Debian。

## 平台适配

自动识别 apt、apk、dnf/yum，分别覆盖 Debian/Ubuntu 系、Alpine 和 RHEL/Rocky/AlmaLinux/Fedora 系。不写死发行版版本；系统仓库需仍然可用。发行版原生软件包按本机架构安装。缺少 microsocks 包时，amd64/arm64 使用项目发布的静态 musl 组件并核验固定 SHA256；其他架构需要发行版提供可用的软件包。[1]

systemd 和 OpenRC 使用各自的服务文件。Alpine 不再被要求运行 systemd。现代 Dropbear 可用时优先使用；旧 Dropbear 不具备严格认证选项时自动使用 OpenSSH，不通过忽略安全选项“兼容”。[2] [3]

**“通用”不等于任何操作系统和权限条件都能运行。** 目前是 Linux 项目，需要 root、可用的软件仓库、实际运行的 systemd/OpenRC 和允许所需网络连接。原生 Windows/macOS、无 init 的裸容器、无对应包和静态组件的架构，不保证支持，脚本会明确报错。模拟适配测试不等于全部发行版真机测试。

## 交互时填写什么

填写任意你有权管理的入口服务器地址、实际公网可访问的 SSH 端口和管理员用户名。管理员需要 root 或免密 sudo；密码直接在 SSH 提示中输入，或填写与所选 SSH 后端匹配的管理员私钥路径。首次连接需通过可信控制台核对主机指纹，不跳过验证。

落地 SOCKS 端口会检测占用并自动建议，也可手动指定；入口反向端口会在入口检测并自动选空闲端口。SSH 公网端口在尚未登录时无法从落地可靠读取，因此由你输入，默认 22。监听检测不等于 NAT 映射或防火墙已放行。

脚本生成独立落地密钥与随机密码，远程配置入口的专用受限隧道账户，匹配两端配置，然后启用落地服务。不改变入口管理 SSH 端口，不改变全局登录认证，不开放公网 SOCKS，也不擅自修改防火墙。

如果选择自动对接 Xray，会发现原生 `xray.service` 单文件 JSON 路径和入站 tag；检测有歧义时显示候选并让你选择。配置先生成候选、校验和备份，再替换/重载，失败时尝试恢复；保留其他入口和原有安全阻断规则。自动合并仍要求入口端是原生 systemd Xray，不能接管 3x-ui 数据库、Docker 独立网络、拆分配置或 JSONC。你可明确选择仅生成合并片段，但这不等于已经完成 Xray 对接。

## 数据路径与边界

```text
客户端 → 任意已配置的 Xray 入口 → 加密 SSH 反向隧道 → 本项目的落地 SOCKS → 互联网
```

入口地理位置没有限制。每套配置连接一个指定入口；若需要同一落地同时供多个入口使用，应为每条隧道增加独立实例，当前默认不是多入口管理面板。没有公网映射端口的 NAT 落地必须主动建立反向连接，无法让未经配置的任意入口直接连接它。

**此版本仅支持 TCP，不支持 UDP。** microsocks 是 SOCKS5 TCP CONNECT 实现，SSH 负责入口到落地的加密。[4] 所选入口 UDP 被阻断，不回退入口直连；游戏、语音和必须使用 UDP 的应用不适用。支持内核 WireGuard 且允许出站 UDP 时可评估完整 TCP+UDP 方案，见 `docs/wireguard.md`。

两端 SOCKS 只监听回环，不是公开的无认证代理。已有客户端仍按原 Xray 协议连接入口。Xray/系统 DNS、应用绕过代理、IPv6 出口需另行按原配置审查，不能仅凭网页 IP 保证没有 DNS 泄漏。

64 MB 内存、1 GB 磁盘只是本项目的低资源设计目标，不是硬件筛选条件，也不保证永不 OOM。更大机器同样可用。依赖安装、基础服务、缓冲区与并发会影响峰值；systemd 的资源保护和 OpenRC 的监管接口也不同。无需在落地机运行面板、Docker、Python 常驻服务或源码编译。建议从个人低并发开始。

## 查看与停止

systemd：

```sh
systemctl status nat-egress-socks nat-egress-tunnel --no-pager
journalctl -u nat-egress-tunnel -n 30 --no-pager
systemctl disable --now nat-egress-tunnel nat-egress-socks
```

OpenRC：

```sh
rc-service nat-egress-socks status
rc-service nat-egress-tunnel status
rc-service nat-egress-tunnel stop
rc-service nat-egress-socks stop
rc-update del nat-egress-tunnel default
rc-update del nat-egress-socks default
```

配置在 `/etc/nat-egress/egress.conf`，私钥在 `/var/lib/nat-egress/.ssh/`；不要上传配置、私钥或备份。`JP_HOST/JP_PORT` 等旧字段名仅用于历史兼容，不代表入口必须在日本。服务进程 active 不是端到端健康确认，安装后应验证真实客户端出口。

## 开发与验证

通用适配层是 `scripts/portable.sh`，向导是 `scripts/setup-head.sh`；`scripts/setup-jp.sh` 保留旧文件名，但配置的是交互指定的任意入口。开发机运行 `python3 build-oneclick.py` 生成独立脚本。`scripts/build-static.sh` 只供开发机生成可复现静态组件，不能在小内存落地执行。

平台、端口、OpenRC 文件和 Xray 合并有模拟/单元测试。隔离数据路径测试可用 `sudo python3 tests/integration.py --backend openssh`；它只使用临时账户和回环服务。实际范围见 `docs/test-results.md`，适配依据见 `docs/platform-sources.md`。尚未部署到用户真实机器，不能声称全部发行版和资源条件已经实测。

## References

[1]: https://pkgs.alpinelinux.org/package/edge/testing/aarch64/microsocks "Alpine microsocks package metadata"
[2]: https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/openssh-client-default "Alpine OpenSSH client dependencies"
[3]: https://packages.ubuntu.com/noble/openssh-client "Ubuntu OpenSSH client package"
[4]: https://github.com/rofl0r/microsocks "MicroSocks upstream README"
