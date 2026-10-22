# 旧 SSH 反向隧道模式

默认安装已经改为 VLESS REALITY。只有无公网入站映射、希望由落地主动连接入口时，才显式使用旧 SSH 模式：

```sh
curl -fsSL https://raw.githubusercontent.com/lengxiv/nat-egress-lite/main/oneclick.sh -o "$HOME/nat-egress-ssh.sh" && bash "$HOME/nat-egress-ssh.sh" --ssh
```

此模式询问入口 SSH 地址、实际公网 SSH 端口和有 root/免密 sudo 权限的管理员。自动选择两端空闲端口，生成受限隧道账户和本地 SOCKS 凭据；原生 systemd Xray 单文件 JSON 可选择自动合并。需要核对主机指纹，不能盲目接受未知服务器。

数据路径是入口 Xray → 加密 SSH 反向隧道 → 落地 microsocks。SOCKS 只监听回环，客户端仍连接原入口。此模式仅支持 TCP，不输出 vless:// 节点；它与默认 VLESS 是不同模式，不要混淆。

服务名为 `nat-egress-socks`、`nat-egress-tunnel`。无入站映射的 NAT 不需要开放落地端口，但入口 SSH 必须可被落地主动连接。全量初版说明与测试可查看仓库 v0.3.0 标签。两种模式不会自动迁移入口路由；64 MB 机器不要无评估地同时常驻多套服务。
