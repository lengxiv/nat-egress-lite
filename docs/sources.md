# 协议与配置依据

目标：Debian 13 trixie / ARM64 / Linux 6.12；落地机 64 MB RAM、1 GB 磁盘；日本入口 Xray。尚未确认公网映射端口、CAP_NET_ADMIN、出站 UDP、实际剩余资源。

默认可交付实现：落地机主动建立 Dropbear SSH 反向 TCP 转发，日本 VPS 的 127.0.0.1:19080 转到落地机 127.0.0.1:1080 microsocks。SSH 承担加密和主机认证，SOCKS5 处理 TCP 请求；不发明加密协议，不把裸 SOCKS5 暴露到互联网。

microsocks 上游明确支持 IPv4、IPv6、域名与 TCP，不支持 UDP；每连接一个小栈线程。源码参考提交：307950cb1296b521fe86384fd695062ade5304b5。[1]

Debian 13 的 dbclient 文档支持 -R、-N、-T、-K、-W、BatchMode、StrictHostKeyChecking、ExitOnForwardFailure。使用已验证 known_hosts，禁止 -y 绕过初次验证。[2]

OpenSSH 服务端使用 Match User、AllowTcpForwarding remote、PermitListen 指定回环地址、PermitOpen none、GatewayPorts no；限制账户会话，避免获得通用 shell 和转发能力。[3]

内核 WireGuard 可由 NAT 落地端主动连接 VPS 公网 UDP endpoint，PersistentKeepalive=25 维持映射。创建内核 WireGuard 接口不依赖 TUN；受限容器仍需要网络管理权限。[4]

## References

[1]: https://github.com/rofl0r/microsocks "MicroSocks upstream README and source"
[2]: https://manpages.debian.org/trixie/dropbear-bin/dbclient.1.en.html "Debian 13 dbclient manual"
[3]: https://man.openbsd.org/sshd_config "OpenSSH server configuration manual"
[4]: https://www.wireguard.com/quickstart/ "WireGuard Quick Start"
