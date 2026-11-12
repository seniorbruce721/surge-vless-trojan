# VLESS REALITY 独立安装器设计

## 意图

在不改动现有 `snell-node.sh` 和 `surge-node.sh` 的前提下，新增面向个人 VPS 的 `vless-node.sh`。它只部署 VLESS + REALITY + XTLS Vision，并生成 Surge 6 可直接复制的节点配置。

## 目标

- 提供 `install`、`show`、`update`、`uninstall`、`status` 命令。
- 使用 XTLS/Xray-core 官方最新稳定 Release，下载后校验 GitHub Release 资产的 SHA-256 digest；无可校验 digest 时拒绝安装或更新。
- 支持 systemd 上的 Debian 12/13 和 Ubuntu 22.04/24.04，CPU 支持 `x86_64` 与 `aarch64`。其他发行版不自动猜测兼容性。
- 服务端仅生成 VLESS + REALITY + `xtls-rprx-vision` 入站，传输为 RAW/TCP，不加 WebSocket、gRPC、XHTTP、CDN 或面板。
- 安装成功后在交互式终端立即显示 Surge `[Proxy]` 行；`show` 使用同一生成逻辑。
- 支持 IPv4-only、IPv6-only 和 IPv4/IPv6 双栈 VPS，并区分“检测到公网地址”与“已验证本地监听”。
- 更新只替换本工具管理的 Xray，保留 UUID、REALITY 密钥、Short ID、端口、SNI、连接地址和地址族监听模式。

## 非目标和禁止事项

- 不修改或重构 `snell-node.sh`、`surge-node.sh` 及其已验证流程。
- 不共用现有 `/usr/local/bin/xray`，不管理 `snell-node.service` 或 `surge-node.service`。
- 不修改 SSH、BBR、sysctl、云安全组、UFW、firewalld 或 nftables。
- 不引入 Docker、Web 管理面板、第三方安装脚本或自动脚本更新。
- 不声称已完成真实 VPS 部署验证。

## 考虑过的方案

1. **完全独立的服务、账户、目录和 Xray 副本（已选择）**：磁盘上可能存在两份 Xray，但安装、更新和卸载边界清晰，不会互相影响。
2. **与 Trojan 共用 `/usr/local/bin/xray`**：节省少量空间，但更新和卸载存在所有权冲突，拒绝采用。
3. **继续扩展 `surge-node.sh`**：复用代码更多，但不符合独立脚本要求并扩大旧安装器职责，拒绝采用。

## 资源所有权与隔离

- systemd 服务：`vless-node.service`
- 系统账户：`vless-node`（无登录 shell）
- 配置目录：`/etc/vless-node`
- Xray 目录：`/usr/local/lib/vless-node`
- Xray 二进制：`/usr/local/lib/vless-node/xray`
- 配置：`/etc/vless-node/config.json`
- 连接元数据：`/etc/vless-node/meta.env`
- Surge 配置：`/etc/vless-node/connections.txt`

安装前只要上述目录、二进制或 unit 已存在，就在任何写入和依赖安装前停止。安装器不将现有的 Snell/Trojan 资源视为冲突，但会通过监听检查拒绝使用已占用端口。

## IPv4 / IPv6 检测与监听策略

1. 分别读取 `ip -4 addr` 和 `ip -6 addr` 的 global scope 地址，排除 loopback、link-local、ULA、文档保留地址以及 tentative/dadfailed/deprecated IPv6。
2. 分别通过 `curl -4` 和 `curl -6` 的 HTTPS 出站探测确认对应公网地址族可用。探测不携带 UUID、密钥、SNI 或配置。探测失败时保留本地地址作为诊断信息，但不将该地址族标记为已验证公网可用。
3. 没有公网 IPv4 不是错误；只要 IPv6 探测成功，IPv6-only 服务器就继续安装。反之亦然。两种地址族均无法验证时停止，并分别输出缺少 global 地址、缺少路由或 HTTPS 出站探测失败等可观测原因。
4. IPv4-only 配置显式监听 `0.0.0.0`；IPv6-only 配置显式监听 `::`。
5. 双栈时先用临时 Xray 进程测试单一 `::` 监听，并用 `nc -4` 连接 `127.0.0.1:<port>`、`nc -6` 连接 `[::1]:<port>` 分别验证。只有两者都成功时才将它记录为单 socket 双栈。
6. 如果内核 `bindv6only=1` 或单一 `::` 无法接收 IPv4，则生成两个配置相同、端口相同的 VLESS 入站，分别监听 `0.0.0.0` 和 `::`。必须再次实际启动临时 Xray 并完成 IPv4/IPv6 两个本地连接测试；任一失败就停止安装。
7. `meta.env` 记录已验证的 IPv4、IPv6、监听模式（`ipv4`、`ipv6`、`dual-single`、`dual-split`）和可选连接域名，供 `show`、`status` 和更新后验证使用。
8. 可选域名必须解析到已检测的本机地址。A、AAAA 或两者匹配时分别输出带 `ip-version=v4-only`、`v6-only` 或 `dual` 的域名版 Surge 节点；记录不匹配时只输出已验证的 IP 版并明确警告。

## 安装流程

1. 验证 root、Linux + systemd、发行版、CPU 架构和目标资源无冲突。
2. 通过 apt 补齐 `ca-certificates`、`curl`、`jq`、`openssl`、`unzip`、`iproute2`、`netcat-openbsd`。
3. 从 XTLS/Xray-core 官方最新稳定 Release 下载匹配架构的 zip，校验官方 SHA-256 digest，解压到本次临时目录。
4. 检测公网 IPv4/IPv6 及地址族出站能力；询问端口（默认 443）、REALITY 目标 SNI 和可选连接域名。SNI 不提供固定默认值，必须为域名。
5. 确认端口在 IPv4 和 IPv6 上均未监听；使用新下载的 `xray tls ping <SNI>:443` 验证目标 TLS 响应。失败则停止，不生成服务。
6. 生成 UUID、X25519 密钥对和 16 位十六进制 Short ID，按已检测的地址族写入候选临时配置，使用 Xray `run -test` 与临时启动/连接检查验证实际监听能力。
7. 仅在上述校验成功后创建系统账户、正式目录、配置和 systemd unit，然后 `daemon-reload` 与 `enable --now`。
8. 等待并验证服务 active、`NRestarts=0`，并按记录模式分别完成 IPv4/IPv6 本地 TCP 连接。失败则删除本次新建资源，不启动半安装服务。
9. 分别检查 IPv4/IPv6 防火墙状态：UFW 显示对应 v4/v6 规则，firewalld 查询活动 zone 的 TCP 端口，nftables/iptables/ip6tables 仅做只读诊断。无法确定时输出 `unknown/manual review required`，绝不自动插入、删除或重置规则。
10. 在交互式终端分别显示已验证的 IPv4、IPv6 节点；可选域名的 A 或 AAAA 与本机地址匹配时，再按实际地址族显示域名版。

## Xray 与 Surge 配置

Xray 只包含 VLESS REALITY 入站。IPv4-only/IPv6-only 和单 socket 双栈使用一个入站；仅当内核需要分离 socket 时使用两个配置相同的入站：

- `protocol`: `vless`
- client `id`: 生成的 UUID
- client `flow`: `xtls-rprx-vision`
- `decryption`: `none`
- 传输：RAW/TCP
- `security`: `reality`
- `target`: `<SNI>:443`
- `serverNames`: `[<SNI>]`
- `privateKey`: 本机生成的 X25519 私钥
- `shortIds`: `[生成的 Short ID]`

Surge 6 输出格式：

```ini
Personal-VLESS = vless, <服务器地址>, <端口>, username=<UUID>, flow=xtls-rprx-vision, sni=<SNI>, reality-public-key=<公钥>, reality-short-id=<Short ID>
```

若地址族可用，分别使用 `Personal-VLESS-IPv4` 和 `Personal-VLESS-IPv6`；由于 Surge 的 VLESS 语法将 host 和 port 作为两个逗号分隔参数，IPv6 使用纯字面量 host，不将方括号当作地址内容。域名记录匹配时再输出 `Personal-VLESS-Domain`，并按实际匹配结果显式加上 `ip-version=v4-only`、`v6-only` 或 `dual`。不得为未通过公网地址探测或本地监听验证的地址族生成“可用”节点。

REALITY 已隐含 TLS，不额外输出 `tls=true`；不输出 `ws`、`grpc` 或 Surge 不使用的 Xray fingerprint 参数。

## 敏感信息与权限

- `umask 077`；配置目录为 `0750 root:vless-node`。
- `config.json`、`meta.env` 和 `connections.txt` 为 `0640 root:vless-node`。
- 私钥仅存在服务器的 `config.json`，不写入 README、Git 或普通日志。
- 脚本不向 journal 输出 UUID、私钥或完整节点。完整节点只在交互式安装结尾和交互式 `show` 中显示。
- 测试仅使用明确的假 UUID、假密钥和文档保留 IP，不写入真实凭据。

## 命令行为

- `install`：执行上述事务化安装，成功后显示节点。
- `show`：从本工具的当前配置与元数据生成同一 Surge 节点；只允许在交互式终端输出。
- `status`：执行 Xray 配置检查，显示 systemd active/enabled、`NRestarts`、记录的网络模式、当前公网 IPv4/IPv6 检测和两个地址族的实际监听状态。
- `update`：在临时目录下载和校验新稳定版，用新二进制测试现有配置，备份旧二进制，替换后重启并验证；失败则回滚旧二进制和旧服务。
- `uninstall`：经互动确认后仅停止并删除 `vless-node.service`、`/etc/vless-node`、`/usr/local/lib/vless-node` 和 `vless-node` 账户；不卸载共用 apt 依赖，不触碰 Snell/Trojan/防火墙。

## systemd 安全边界

- `User=vless-node` 和 `Group=vless-node`。
- 通过 `AmbientCapabilities=CAP_NET_BIND_SERVICE` 和 `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` 允许非 root 绑定 443。
- 使用 `NoNewPrivileges=true`、`PrivateTmp=true`、`ProtectSystem=strict`、`ProtectHome=true`。
- 服务只读取 `/etc/vless-node`，不赋予修改其他服务或系统配置的权限。

## 测试与验收

新增 `tests/test_vless_node.sh`，使用临时根目录和假系统命令验证：

- Debian 12/13、Ubuntu 22.04/24.04 通过，其他系统拒绝。
- x86_64/aarch64 资产选择与官方 digest 校验的失败关闭行为。
- 无固定 SNI 默认值，TLS ping 失败时不创建服务。
- IPv4-only、IPv6-only、单 socket 双栈和分离 socket 双栈四种 fixture；缺少 IPv4 不得使 IPv6-only 安装失败。
- 对单一 `::` 监听的 IPv4/IPv6 连接结果分别断言，不以配置文本推断双栈成功。
- 生成的 Xray JSON 只包含 VLESS/REALITY/Vision RAW 入站，且入站数量与监听模式一致。
- Surge 输出参数符合官方文档，安装与 `show` 共用同一渲染结果；按实际可用性输出 IPv4、IPv6 及 A+AAAA 域名版。
- 防火墙检查分开报告 IPv4/IPv6，但假 UFW/firewalld/nftables/iptables/ip6tables 哨兵证明没有写操作。
- 已有目录、unit、二进制或监听端口导致安装在写入前停止。
- `update` 保留 UUID、密钥、Short ID、端口、SNI，更新失败会回滚。
- `uninstall` 删除自有资源，Snell/Trojan/防火墙哨兵文件保持不变。
- 安装失败时清理本次临时目录和新建资源。

最终执行 Bash 语法检查、新增测试、全部现有测试、`git diff --check` 和敏感数据/无关系统命令扫描。由于本任务禁止连接 VPS，最终报告必须明确标注：**只完成本地静态与 fixture 测试，未在真实 VPS 部署验证。**

## 预期修改文件

- 新增 `vless-node.sh`
- 新增 `tests/test_vless_node.sh`
- 更新 `README.md`
- 新增本设计文档和后续实施计划

## 已知风险

- 本地 fixture 无法替代真实 Debian/Ubuntu、systemd、公网监听和 Surge 客户端连接验证。
- `xray tls ping` 可验证目标 TLS 响应，但无法仅凭脚本可靠证明目标与 VPS 同 ASN，也无法完全识别 CDN 滥用风险。README 将要求用户选择自己验证的直连 TLS 1.3 目标，避免免费 CDN 域名。
- 脚本不修改防火墙；即使本地服务 active/listening，公网仍可能因云安全组或主机防火墙不通。
- 服务器内部可验证公网地址族出站和本地 IPv4/IPv6 监听，但在没有外部探针时不能证明公网入站已穿过云安全组与防火墙。输出会明确区分“本地已监听”和“公网入站未验证”。
- Surge 的 VLESS 支持要求 iOS 6.0+ 或 macOS 6.12+，旧版本无法使用该节点。
