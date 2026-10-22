# NAT Egress Lite — VLESS + REALITY 落地一键部署

默认部署独立 **VLESS + TCP + REALITY + XTLS Vision** 服务，并输出真正的 `vless://` 节点链接。不再默认部署 SOCKS/SSH 隧道，不需要脚本登录日本入口，也不限制入口位于哪个国家。

## 一键命令

在准备作为落地的 Linux 机器上以 root 执行：

```sh
curl -fsSL https://raw.githubusercontent.com/lengxiv/nat-egress-lite/main/install.sh -o "$HOME/nat-egress-install.sh" && sh "$HOME/nat-egress-install.sh"
```

入口会补齐缺失的 Bash，再下载内嵌完整向导的 `oneclick.sh`。无需 GitHub Token、Git、Python、Docker 或落地源码编译。自动检测 apt/apk/dnf/yum 与实际运行的 systemd/OpenRC；官方 Xray 下载按 amd64、ARM64、x86 32 位、ARMv7 匹配，并核验固定 SHA256。

## 向导填写与输出

本机已监听的 TCP 端口会显示出来，脚本自动建议空闲监听端口，也可手动输入。接着填写客户端实际能访问的公网 IP/域名与公网端口；NAT 的外部映射端口可能与本机监听端口不同。出网 IP 自动检测仅作建议，不能代替商家面板里的入站地址。

UUID、REALITY 私钥/公钥和 short ID 自动生成。默认目标 SNI 是 `www.microsoft.com`，可以改成从落地能访问且符合 REALITY 要求的 TLS 目标。无需域名归属或申请本机 TLS 证书，但目标 TLS 服务、网络条件和客户端版本仍需正确。

例如本机监听 `8443`，商家把公网 `192.0.2.10:30443` 映射到该端口，完成后会显示以下格式。这里是占位示例，不能直接连接：

```text
VLESS REALITY 已监听：0.0.0.0:8443；分享链接使用 192.0.2.10:30443。
vless://<自动生成UUID>@192.0.2.10:30443?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=<自动生成公钥>&sid=<自动生成shortID>&type=tcp&flow=xtls-rprx-vision&spx=%2F#NAT-Egress
```

链接保存在 `/etc/nat-egress-vless/node.url`，可以导入支持 VLESS 分享链接的客户端或面板。再次查看：

```sh
bash oneclick.sh --show-link
# 或
cat /etc/nat-egress-vless/node.url
```

入口是原生 Xray 时，原生核心不会直接读取 `vless://` URL。脚本还生成 `/etc/nat-egress-vless/outbound.json`：从文件取出 VLESS 出站并合并到入口现有 `outbounds`，让所需路由指向 `nat-egress-vless-reality`。不要直接覆盖入口整份配置。模板使用当前 Xray 的 REALITY `password` 字段；旧核心可能需要旧名称 `publicKey`，也可通过支持分享链接的管理工具转换。

## NAT 与资源边界

**直连 VLESS 必须有可访问的入站 TCP 端口。** NAT 商家提供的 TCP 映射、主机防火墙和安全组需要放行。脚本不会假装已经识别商家的映射，也不擅自改现有防火墙。如果 NAT 只允许主动出网、没有任何入站映射，则本模式不能让其他机器直接访问；需另外增加入口转发/反向隧道，不能靠一条分享链接绕过 NAT。

64 MB 内存与 1 GB 磁盘是低资源设计目标，不是硬件限制或成功保证。VLESS 使用 Xray，其常驻与峰值高于旧 microsocks 方案。配置采用单 Go 调度器、24MiB Go 软内存目标和低文件描述符上限；systemd 另设 44M 服务内存上限，OpenRC 并无等价的硬 cgroup 上限。Go 软目标不等于 RSS 或整机内存，基础系统和安装工具仍可能 OOM。建议低并发实测；无法承诺 64 MB 长期稳定。

不下载 GeoIP/GeoSite 数据库，不开面板，不启用 mux 或无限访问日志。默认使用显式 CIDR 阻断私网、回环和链路本地目的地。NAT 只需映射服务的 TCP 端口；UDP 转发能力还取决于客户端、Vision 策略和落地出站网络，不能单凭 TCP 监听保证所有 UDP 应用可用。

## 独立安装与管理

核心与运行器位于 `/usr/local/lib/nat-egress-vless/`，配置位于 `/etc/nat-egress-vless/`，服务是 `nat-egress-vless`，采用独立低权限账户 `nat-vless`。不会覆盖机器原有的 `/usr/local/bin/xray` 或其他 Xray 配置。重复安装保留本项目 UUID/密钥，更新期间短暂停止旧 VLESS；失败分支尝试恢复旧核心和配置，但没有进行所有真实系统的回滚演练。

systemd：

```sh
systemctl status nat-egress-vless --no-pager
journalctl -u nat-egress-vless -n 30 --no-pager
systemctl disable --now nat-egress-vless
```

OpenRC：

```sh
rc-service nat-egress-vless status
rc-service nat-egress-vless stop
rc-update del nat-egress-vless default
```

链接、`info.env` 与配置包含凭据，不要上传到公开仓库。没有 root、没有真实 init、没有对应架构组件或网络权限的机器不能保证支持。原生 Windows/macOS 不属于本项目安装范围。

旧 SSH 反向隧道仍保留，但必须显式使用 `bash oneclick.sh --ssh`，见 `docs/ssh-mode.md`。如果旧服务已经运行，不会自动迁移入口路由或停止它；小内存机器应在新节点验证后停用不再需要的旧服务。

## 实际验证

配置/URI 单元测试已覆盖公网端口、IPv6 方括号、UTF-8 名称编码、私钥不出现在分享链接/入口出站、0600 权限和非法输入拒绝。官方 Xray 26.10.21 ARM64 已校验生成的服务端与入口出站配置。尚未在用户 NAT 真机部署、验证商家映射或进行 64 MB 整机长期压测；服务 active 与监听成功不是公网端到端成功的证明。

配置依据见 `docs/vless-sources.md`，详细历史测试范围见 `docs/test-results.md`。独立脚本由 `python3 build-oneclick.py` 在开发机生成；部署端不用 Python。
