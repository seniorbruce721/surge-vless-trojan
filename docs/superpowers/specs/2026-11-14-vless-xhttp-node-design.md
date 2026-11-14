# 独立 VLESS XHTTP 节点设计

## 目标

新增 `vless-xhttp-node.sh`，在不修改现有 `snell-node.sh`、`vless-node.sh`、`surge-node.sh` 及其服务的前提下，部署两个可独立存在的测试实例：

- `plain`：VLESS + XHTTP + REALITY，固定 `stream-one`；
- `encryption`：上述组合再启用由 Xray 官方 `vlessenc` 生成的 `mlkem768x25519plus` VLESS Encryption。

脚本只支持 Debian 12/13、Ubuntu 24.04/26.04，使用 systemd，支持 `install`、`show`、`status`、`uninstall`。

## 官方协议依据

- Xray 官方示例使用 `streamSettings.network = "xhttp"`、`xhttpSettings.path` 和 `security = "reality"`。
- 本脚本显式写入 `xhttpSettings.mode = "stream-one"`，并要求 REALITY 目标支持 TLS 1.3 与 HTTP/2。
- 普通模式入站 `decryption = "none"`。
- Encryption 模式的服务端 `decryption` 与客户端 `encryption` 只能来自当前下载的 Xray 执行 `xray vlessenc` 的结果，脚本不拼接或猜测格式。

Surge 6.100.0 (4026) 的 TestFlight 更新日志是本次客户端能力判断的依据。公开在线手册尚未给出可核验的 XHTTP/Encryption `[Proxy]` 完整参数语法，因此脚本只输出完整节点字段与 Xray 标准分享信息；任何 Surge 专用配置行必须先通过 4026 的节点编辑器或分享链接导入确认，未确认前不得伪装为已验证语法。

## 资源隔离

两个模式使用固定映射，不接受任意路径或服务名：

| 模式 | systemd 服务 | 配置目录 | 二进制目录 | 默认端口 |
| --- | --- | --- | --- | --- |
| plain | `vless-xhttp-plain.service` | `/etc/vless-xhttp-node/plain` | `/usr/local/lib/vless-xhttp-node/plain` | 24443 |
| encryption | `vless-xhttp-encryption.service` | `/etc/vless-xhttp-node/encryption` | `/usr/local/lib/vless-xhttp-node/encryption` | 24444 |

每个模式有独立用户、UUID、REALITY 密钥、Short ID、XHTTP path、配置、连接信息和 Xray 二进制。卸载一种模式不能接触另一种模式，也不能接触 Snell、现有 VLESS/Trojan、SSH、BBR、sysctl 或防火墙。

## 安装流程

1. 校验 root、Linux/systemd、发行版与架构。
2. 检查目标模式的固定资源尚不存在。
3. 安装必要依赖；不改网络、SSH 或防火墙。
4. 检测公网 IPv4/IPv6 与本机监听能力。
5. 要求用户输入端口和已自行确认可用的 REALITY SNI；端口检测失败或占用立即停止。
6. 从 XTLS/Xray-core 最新稳定 Release 下载架构匹配的 zip，并强制核对 Release asset SHA-256 digest。
7. 用 Xray 生成 UUID、REALITY X25519 密钥和 Short ID；Encryption 模式额外运行 `xray vlessenc`。
8. 生成候选配置并先执行 `xray run -test -config ...`。
9. 通过临时进程分别验证 IPv4/IPv6 本地连接，选择 `ipv4`、`ipv6`、`dual-single` 或 `dual-split`。
10. 写入严格权限的配置和元数据，创建独立 systemd unit，启动并验证 active、enabled、NRestarts=0 和监听。
11. 成功后在交互终端显示完整节点信息；非交互输出不泄露 UUID、密钥或 Encryption 参数。

任一步失败都回滚本次模式创建的资源并清理临时目录，不停止或重启任何既有代理服务。

## 双栈与防火墙

脚本沿用“能力检测后实测”的策略：先试单个 `::` 是否同时服务 IPv4/IPv6，失败则使用同端口双 inbound。IPv6-only 不依赖 IPv4。脚本只读取 UFW/firewalld/nftables 状态并提示用户自行放行 TCP 端口，绝不添加、删除、重载或重置规则。

## 验证边界

自动化测试覆盖配置结构、官方 `vlessenc` 输出解析、双栈模式、端口失败关闭、两个模式隔离、回滚和卸载边界。使用当前官方稳定 Xray 执行 `run -test`。

仍需真实 VPS/Surge 验证：公网 IPv4/IPv6 握手、REALITY 目标质量、HTTP/2 实际协商、Surge 4026 编辑器/分享链接参数映射、Encryption 实际握手、与现有 Snell/VLESS 长时间并行运行。
