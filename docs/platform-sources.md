# 通用 Linux 适配依据

安装器按实际可用的 apt/apk/dnf/yum 选择软件仓库，不再绑定 Debian 13，也不通过用户提供的机器型号选择固定二进制。发行版软件包自然匹配本机架构；无 microsocks 包时才使用项目发布的 amd64/arm64 静态组件，并检查内嵌的固定 SHA256。

Alpine 官方索引显示 microsocks 当前位于 edge/testing，因此不能假设稳定版默认仓库一定提供它。不能为了安装项目擅自启用 edge/testing；应使用校验过的独立组件回退。[1]

Alpine openssh-client-default 依赖 openssh-keygen 和 openssh-client-common；可作为没有现代 Dropbear 的客户端后端。[2] Ubuntu 的 openssh-client 提供标准 SSH 客户端，仓库可按目标平台安装。[3]

OpenRC 服务采用官方 supervise-daemon 监管前台进程；respawn_delay=10，respawn_max=0 用于无限重启，command_user 设置低权限账户。[4] [5] systemd 与 OpenRC 文件是不同服务接口，不能只删除发行版判断却继续调用 systemctl。

适配逻辑与模拟测试不等于每个发行版、内核或厂商容器都已实测。没有 root、真实服务管理器或所需网络/执行能力的环境应明确报错，不声称任意 Windows/macOS/无 init 容器均支持。

## References

[1]: https://pkgs.alpinelinux.org/package/edge/testing/aarch64/microsocks "Alpine microsocks package metadata"
[2]: https://pkgs.alpinelinux.org/package/v3.23/main/aarch64/openssh-client-default "Alpine OpenSSH client dependencies"
[3]: https://packages.ubuntu.com/noble/openssh-client "Ubuntu OpenSSH client package"
[4]: https://github.com/OpenRC/openrc/blob/master/supervise-daemon-guide.md "OpenRC supervise-daemon guide"
[5]: https://github.com/OpenRC/openrc/blob/master/man/openrc-run.8 "OpenRC service configuration reference"
