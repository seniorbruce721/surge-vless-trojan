# VLESS XHTTP 独立安装器实施计划

1. 建立行为测试：模式映射、系统支持、XHTTP+REALITY 配置、Encryption 生成、端口失败关闭、资源隔离和卸载边界。
2. 实现独立 `vless-xhttp-node.sh`，只管理 plain/encryption 的固定资源。
3. 使用 Xray 官方稳定版对普通和 Encryption 配置运行 `xray run -test`。
4. 更新 README，说明命令、敏感信息、Surge 4026 语法验证边界和实机待验证项。
5. 运行 Bash 语法、全部仓库测试、diff 检查和敏感信息扫描。
6. 提交、推送 `codex/vless-xhttp-encryption` 并创建 PR，不连接或部署任何 VPS。
