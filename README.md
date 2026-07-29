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
