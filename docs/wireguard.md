# WireGuard（可选内核点对点链路）

本项目默认的 **microsocks + Dropbear 反向 SSH** 是 TCP-only，且不依赖 TUN。WireGuard 是可选方案，不是默认替换；尚未获授权时，**不要在真实 VPS 或落地机部署、安装软件或修改防火墙**。

适用前提：日本 VPS 有可访问的公网 UDP 端口；落地机可发出 UDP。Debian 13 ARM64 的 6.12 内核是否可用，仍取决于内核配置、模块与容器/服务商是否授予 `CAP_NET_ADMIN`。先做无安装、无路由、防火墙或配置改动的探测：

```sh
command -v ip || { echo 'ip missing（未安装 iproute2，无法探测）'; exit 127; }
sudo ip link add wg-probe type wireguard
rc=$?
[ "$rc" -ne 0 ] || sudo ip link del wg-probe
exit "$rc"
```

成功后立即删除的只是一个空接口；这不需要 `/dev/net/tun`。常见失败含义：

| 输出/现象 | 含义与下一步 |
|---|---|
| `ip missing` 或 `ip: command not found` | 没有 `ip`（通常是 `iproute2`）；此探测不会自行安装任何包。仅在获授权的维护窗口按 [官方安装说明](https://www.wireguard.com/install/) 准备工具后再继续。 |
| `RTNETLINK answers: Operation not permitted` / `not permitted` | 缺少 `CAP_NET_ADMIN`（常见于受限容器）；不能在当前实例创建内核 WG 接口。 |
| `RTNETLINK answers: Operation not supported` / `not supported` | 内核未提供 WireGuard link 类型，或模块不可用；应向服务商确认内核能力。 |

只有探测成功**且**落地机到 VPS 公网 `UDP/<端口>` 可达时，才优先使用内核 WireGuard。落地机无需 NAT 的入站端口映射：它主动向 VPS 的公网 endpoint 发包；`PersistentKeepalive = 25` 用于维持该出站 NAT 状态。它不能绕过「落地机禁止 UDP 出站」或「VPS UDP 被安全组/防火墙拦截」。

## 最小点对点模板

在已按官方文档安装 WireGuard 用户态工具、分别生成两端密钥并妥善保护私钥后，将占位符替换为实际值。VPS 上监听的 UDP 端口须由其现有安全组/防火墙明确放行；本文不提供变更防火墙的命令。

`/etc/wireguard/wg0.conf`（日本 VPS）：

```ini
[Interface]
Address = 10.77.0.1/32
ListenPort = 51820
PrivateKey = <VPS_PRIVATE_KEY>
Table = off

[Peer]
PublicKey = <LANDING_PUBLIC_KEY>
AllowedIPs = 10.77.0.2/32
```

`/etc/wireguard/wg0.conf`（落地机）：

```ini
[Interface]
Address = 10.77.0.2/32
PrivateKey = <LANDING_PRIVATE_KEY>

[Peer]
PublicKey = <VPS_PUBLIC_KEY>
Endpoint = <VPS_PUBLIC_IP_OR_DNS>:51820
AllowedIPs = 10.77.0.1/32
PersistentKeepalive = 25
```

这只声明两端 `10.77.0.1/32` 与 `10.77.0.2/32`，每个 peer 的 `AllowedIPs` 也仅为对端 `/32`。VPS 的 `Table = off` 禁止 `wg-quick` 根据 `AllowedIPs` 自动添加路由；落地机没有 `0.0.0.0/0` 或 `::/0`，最多只会为 VPS 隧道地址添加一条 `/32` 路由。因此模板本身不接管全局默认路由。

在可回滚的维护窗口，可临时拉起后检查握手，再立即关闭：

```sh
sudo wg-quick up wg0
sudo wg show wg0
# 两端均有 recent handshake 后，按需从落地机测试：ping -c 3 10.77.0.1
sudo wg-quick down wg0
```

`wg show` 中出现最近握手才证明 endpoint 的 UDP 往返可用；仅接口创建成功并不代表 UDP 路径可达。

## 边界与后续设计

上述模板**不等于已经完成 TCP+UDP 完整落地**，它只建立受限的点对点地址连通性。要把 VPS 上特定 Xray 流量经隧道送往落地出口，还需要结合现有环境逐项设计并验证：

- VPS：只为目标 Xray 出站建立**特定**策略路由/`mark`，避免把 SSH、WireGuard endpoint 回程或 Xray 自身入口错误送入隧道形成回环。
- 落地机：为来自 `wg0` 的目标流量配置转发、到实际出口的 NAT，以及对应的回程路径。
- IPv6 与 DNS：明确采用与 IPv4 一致的转发策略，或做 fail-closed；不能让 DNS 或 IPv6 绕过预期出口。

这些步骤依赖现有 Xray、默认路由、防火墙与上游网络，不能盲目套用。为避免断开 SSH 或造成 Xray 出站回环，本文特意**不提供**全局默认路由、`ip rule`、`iptables`/`nft`、NAT、`PostUp`/`PreDown` 或 DNS 修改命令。

即使 WireGuard 已握手，本项目现有 SSH SOCKS 也不会自动获得 UDP 能力；它仍是 TCP-only。若需要 UDP，必须在完成上述端到端路由/NAT 设计后，另行提供匹配的 UDP 接入与验证方案。

## References

1. WireGuard, [Quick Start](https://www.wireguard.com/quickstart/).
2. WireGuard, [Installation](https://www.wireguard.com/install/).
