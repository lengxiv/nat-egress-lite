# VLESS + REALITY 配置依据

`scripts/vless-config.sh` 固定生成 **VLESS + TCP + REALITY + `xtls-rprx-vision`**。服务端入站使用 `decryption: "none"`，客户端 VLESS 用户使用 `encryption: "none"`；这不是无传输安全的明文配置，因为传输层明确设置为 `security: "reality"`。[1] [2]

服务端 REALITY 使用当前字段 `target: "SNI:443"`。官方说明指出旧字段 `dest` 与 `target` 目前互为别名，但当前名称是 `target`，而且该字段用于识别服务端配置。[1] 因此生成器不写已废弃名称。`serverNames` 与客户端 `serverName` 均来自同一个受限 ASCII 域名输入。

当前 Xray 客户端配置把 REALITY X25519 公钥放在 `realitySettings.password`；文档明确说明它是对应服务端私钥的公钥，旧字段名为 `publicKey`。[1] 所以 `outbound.json` 使用 `password`。私钥只放入服务端 `config.json`，不会出现在 `node.url` 或入口侧 `outbound.json`。

分享链接使用 `pbk`、`sid`、`fp=chrome`、`spx=%2F` 和 `security=reality`。上游链接提案规定 IPv6 remote host 必须加方括号，参数值及描述名称使用 `encodeURIComponent` 语义转义；其中 `pbk` 对应当前配置的 `password`，`sid` 对应 `shortId`。[3] 名称编码由 Bash 在 `LC_ALL=C` 下逐 UTF-8 字节完成，部署端不依赖 Python。

生成的服务端仅含 `freedom` 直连与为私网拦截所需的 `blackhole`；路由使用 `IPIfNonMatch`，并列出 RFC1918、回环、链路本地、ULA 等 CIDR，不依赖 `geoip.dat` 或 `geosite.dat`。`NE_PUBLIC_HOST` 和 `NE_PUBLIC_PORT` 只是经过语法与本地/私网拒绝检查的运营者输入。生成器不会声称 NAT 映射、防火墙或外网可达性已经验证。

**References**

[1]: https://xtls.github.io/en/config/transports/reality.html "Xray REALITY configuration"
[2]: https://xtls.github.io/en/config/outbounds/vless.html "Xray VLESS outbound configuration"
[3]: https://github.com/XTLS/Xray-core/discussions/716 "VLESS share link standard proposal"
