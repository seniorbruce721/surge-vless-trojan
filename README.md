# Surge VLESS + Trojan Node

个人使用的精简 Xray 部署脚本，目标是：

- `VLESS + Reality + Vision`：供支持 VLESS 的客户端使用；
- `Trojan + TLS`：供 Surge 使用。

它不安装 Docker、WARP、Cloudflare Tunnel、面板、订阅服务或多用户计费；不修改 SSH 和防火墙；也不会自动更新自身。

## 支持范围

- Debian 12、Ubuntu 24.04 LTS
- x86_64、aarch64
- Trojan 需要一个已解析到本机公网 IP 的域名

## 安全原则

1. 不要使用 `curl | bash`。下载本仓库后再执行。
2. Xray 从官方 GitHub Release 下载；没有 SHA-256 digest 时脚本拒绝安装。
3. 不自动开放端口。你必须在服务商安全组和本机防火墙中按需放行。
4. 配置、Reality 私钥、Trojan 密码及连接信息保存在 `/etc/surge-node`，不应提交 GitHub。

## 使用前检查

- 先创建 VPS 快照。
- 确认 TCP 80 可以从公网访问：Certbot standalone 需要它申请和续期 Trojan 的证书。
- 若 Nginx、Caddy 或 Apache 已占用 TCP 80，本脚本会停止，避免干扰现有网站。
- 默认端口：VLESS Reality TCP 443，Trojan TCP 8443。

## 使用

```bash
sudo bash surge-node.sh install
sudo bash surge-node.sh status
sudo bash surge-node.sh show
sudo bash surge-node.sh update
sudo bash surge-node.sh backup /root
sudo bash surge-node.sh uninstall
```

安装完成后会输出 VLESS Reality URI，以及可直接放入 Surge `[Proxy]` 段的 Trojan 配置行。

若使用 UFW，除服务商安全组外还要手动按实际端口放行：

```bash
sudo ufw allow 443/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 80/tcp
```

备份不含 TLS 私钥；证书由 Certbot 管理。请遵守所在地法律、网络服务商和 VPS 服务商条款。

---

# Surge Snell Node

`snell-node.sh` 是给个人 Surge 使用的 Snell 服务端脚本。它与上面的 VLESS/Trojan 脚本互不依赖，使用独立的：

- 服务：`snell-node.service`
- 账户：`snell-node`（无登录 shell）
- 配置目录：`/etc/snell-node`
- 二进制：`/usr/local/bin/snell-server`

## Snell 支持范围

- 仅 Linux + systemd；CPU 仅 `x86_64`、`aarch64`。
- 通过 `/etc/os-release` 识别发行版：Debian/Ubuntu 使用 `apt`，Fedora 使用 `dnf`，RHEL/Rocky/AlmaLinux 等按实际可用工具选择 `dnf` 或 `yum`，仅 Arch Linux 使用 `pacman`。未识别系统会明确退出；这意味着不再把系统版本硬编码为 Ubuntu 24.04 / Debian 12，但不等于承诺所有发行版都能运行。
- 只下载官方 `dl.nssurge.com` 的当前可用版本：Snell v4.1.1、v5.0.1（默认推荐）、v6.0.0rc2 Beta。
- v1-v3 不自动安装：当前官方地址不提供可验证的安装包，脚本不会改用未知第三方镜像。
- v6 是 Beta；使用前确认 Surge 客户端版本支持 Snell v6。仅提供 `default` 和 `unshaped`，不提供风险更高的 `unsafe-raw`。

## 安全边界

1. 不修改 SSH、UFW、云安全组、sysctl、BBR、时区。
2. 下载限定 HTTPS，并校验 zip 完整性和二进制能否执行；下载失败时停止，不切换第三方来源。
3. 自动随机生成 PSK；连接信息只写入服务器的 `/etc/snell-node/connections.txt`（权限 `640`），不会上传到 GitHub。
4. `update` 更新失败会尝试回滚二进制；`uninstall` 仅删除本脚本创建的服务、程序与 `/etc/snell-node`，不碰防火墙规则。

## 安装

先在 VPS 服务商安全组及 UFW 中，放行你自己选择的 Snell 端口的 **TCP 和 UDP**。默认推荐端口是 `6160`；不要与现有服务冲突。

```bash
git clone https://github.com/seniorbruce721/surge-vless-trojan.git
cd surge-vless-trojan
sudo bash snell-node.sh install
```

安装时依次填写：Snell 大版本、给 Surge 使用的域名或公网 IP、端口；v6 还会询问模式。成功后会直接打印一行可复制到 Surge 配置 `[Proxy]` 段的内容。

常用命令：

```bash
sudo bash snell-node.sh status
sudo bash snell-node.sh show
sudo bash snell-node.sh update
sudo bash snell-node.sh update 6
sudo bash snell-node.sh uninstall
```

`show` 会显示 PSK，避免截图、发送到聊天软件或提交到 GitHub。Surge 的 Snell 版本必须与服务端安装版本一致；v6 的客户端兼容性请以 [Surge 官方 Snell 文档](https://manual.nssurge.com/policies/snell.html) 为准。
