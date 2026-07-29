#!/usr/bin/env bash
# Personal VLESS Reality + Trojan node for Debian 12 / Ubuntu 24.04.
# Intentionally no self-update, Docker, WARP, tunnel, panel or firewall mutation.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly APP='surge-node'
readonly DIR='/etc/surge-node'
readonly BIN='/usr/local/bin/xray'
readonly UNIT='surge-node'
readonly USER='surge-node'
readonly CONFIG="$DIR/config.json"
readonly TLS="$DIR/tls"
readonly CONNECTIONS="$DIR/connections.txt"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
root() { [[ $EUID -eq 0 ]] || die '请用 root 或 sudo 运行。'; }

usage() {
  cat <<'EOF'
用法：surge-node.sh <命令>
  install          安装并申请 Trojan TLS 证书
  status           验证配置，显示服务与监听端口
  show             显示连接信息（包含敏感凭据）
  update           手动校验并更新 Xray
  backup <目录>    备份配置和连接信息，不含 TLS 私钥
  uninstall        删除本脚本创建的服务、二进制和配置
EOF
}

check_os() {
  . /etc/os-release
  case "${ID}:${VERSION_ID}" in debian:12|ubuntu:24.04) ;; *) die "仅支持 Debian 12 / Ubuntu 24.04；当前：${PRETTY_NAME:-未知}" ;; esac
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "不支持的架构：$(uname -m)" ;; esac
}

deps() {
  export DEBIAN_FRONTEND=noninteractive
  info '安装依赖：curl、jq、unzip、Certbot…'
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl jq openssl unzip certbot
}

release_asset() {
  # Output: URL|SHA256. Refuse assets without an official GitHub digest.
  local repo="$1" asset="$2" release url digest
  release=$(curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/$repo/releases/latest") || return 1
  url=$(jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$release" | head -n1)
  digest=$(jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .digest // empty' <<<"$release" | head -n1)
  [[ -n "$url" && "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s|%s\n' "$url" "${digest#sha256:}"
}

install_xray() {
  local arch asset pair url expected actual temp
  case "$(uname -m)" in x86_64) arch=64 ;; aarch64) arch=arm64-v8a ;; esac
  asset="Xray-linux-$arch.zip"
  info '下载官方 Xray Release，并校验 SHA-256…'
  pair=$(release_asset XTLS/Xray-core "$asset") || die '官方 Release 未提供可校验 digest；已拒绝安装。'
  url=${pair%%|*}; expected=${pair##*|}
  temp=$(mktemp -d)
  trap 'rm -rf "$temp"' RETURN
  curl -fsSL --connect-timeout 20 --retry 2 -o "$temp/xray.zip" "$url"
  actual=$(sha256sum "$temp/xray.zip" | awk '{print $1}')
  [[ "${actual,,}" == "${expected,,}" ]] || die 'Xray SHA-256 校验失败。'
  unzip -q "$temp/xray.zip" -d "$temp/out"
  [[ -x "$temp/out/xray" ]] || die '发布包中未找到 xray。'
  install -m 0755 "$temp/out/xray" "$BIN"
  install -d -m 0755 /usr/local/share/xray
  find "$temp/out" -maxdepth 1 -type f -name '*.dat' -exec install -m 0644 {} /usr/local/share/xray/ \;
  "$BIN" version >/dev/null
  trap - RETURN
  rm -rf "$temp"
}

ask() { local v; read -r -p "$1${2:+ [$2]}: " v; printf '%s' "${v:-$2}"; }
valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
port_free() { ! ss -lnt | awk '{print $4}' | grep -Eq "[:.]$1$"; }
password() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9._~!@%+=,-' | head -c 24; }

prepare_dir() {
  id -u "$USER" >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin "$USER"
  install -d -o root -g "$USER" -m 0750 "$DIR" "$TLS"
}

issue_cert() {
  local domain="$1" email="$2"
  if ss -lnt | awk '{print $4}' | grep -Eq '(:|\.)80$'; then
    die 'TCP 80 已被占用。为保护现有网站，本脚本拒绝继续；请改用 DNS 验证方案。'
  fi
  info "使用 Certbot standalone 为 $domain 申请证书（需要公网 TCP 80）…"
  certbot certonly --non-interactive --agree-tos --email "$email" --standalone -d "$domain"
  install -o root -g "$USER" -m 0640 "/etc/letsencrypt/live/$domain/fullchain.pem" "$TLS/fullchain.pem"
  install -o root -g "$USER" -m 0640 "/etc/letsencrypt/live/$domain/privkey.pem" "$TLS/privkey.pem"
  install -d -m 0750 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/surge-node <<EOF
#!/bin/sh
set -eu
install -o root -g $USER -m 0640 /etc/letsencrypt/live/$domain/fullchain.pem $TLS/fullchain.pem
install -o root -g $USER -m 0640 /etc/letsencrypt/live/$domain/privkey.pem $TLS/privkey.pem
systemctl restart $UNIT
EOF
  chmod 0700 /etc/letsencrypt/renewal-hooks/deploy/surge-node
}

write_config() {
  local rp="$1" tp="$2" uuid="$3" private="$4" sid="$5" sni="$6" domain="$7" pass="$8"
  cat > "$CONFIG" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"tag":"vless-reality","listen":"::","port":$rp,"protocol":"vless","settings":{"clients":[{"id":"$uuid","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"$sni:443","xver":0,"serverNames":["$sni"],"privateKey":"$private","shortIds":["$sid"]}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}},
    {"tag":"trojan-tls","listen":"::","port":$tp,"protocol":"trojan","settings":{"clients":[{"password":"$pass"}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"$TLS/fullchain.pem","keyFile":"$TLS/privkey.pem"}]}}}
  ],
  "outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]
}
EOF
  chown root:"$USER" "$CONFIG"; chmod 0640 "$CONFIG"
}

write_unit() {
  cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Personal VLESS Reality and Trojan node
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=$USER
Group=$USER
ExecStart=$BIN run -config $CONFIG
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=$DIR
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_connections() {
  local rp="$1" tp="$2" uuid="$3" public="$4" sid="$5" sni="$6" domain="$7" pass="$8" host
  host=$(curl -fsSL --max-time 10 https://api.ipify.org || true); host=${host:-YOUR_SERVER_IP}
  cat > "$CONNECTIONS" <<EOF
# 敏感文件：不要上传、截图或分享。
# VLESS Reality（Surge 不支持；供其他客户端导入）
vless://$uuid@$host:$rp?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$public&sid=$sid&type=tcp&headerType=none#Personal-Reality

# Surge [Proxy] 中使用的 Trojan 节点：
Personal-Trojan = trojan, $domain, $tp, password=$pass, sni=$domain
EOF
  chown root:"$USER" "$CONNECTIONS"; chmod 0640 "$CONNECTIONS"
}

install_node() {
  local domain email rp tp sni uuid pair private public sid pass
  check_os; deps; install_xray; prepare_dir
  domain=$(ask 'Trojan 域名（须已解析到本机公网 IP）'); valid_domain "$domain" || die '域名格式无效。'
  email=$(ask '证书通知邮箱'); [[ "$email" == *@*.* ]] || die '邮箱格式无效。'
  rp=$(ask 'VLESS Reality TCP 端口' 443); tp=$(ask 'Trojan TCP 端口' 8443); sni=$(ask 'Reality 目标 SNI' www.microsoft.com)
  valid_port "$rp" && valid_port "$tp" && [[ "$rp" != "$tp" ]] || die '端口无效或重复。'
  port_free "$rp" || die "端口 $rp 已被占用。"; port_free "$tp" || die "端口 $tp 已被占用。"; valid_domain "$sni" || die 'Reality SNI 必须是域名。'
  issue_cert "$domain" "$email"
  uuid=$("$BIN" uuid); pair=$("$BIN" x25519); private=$(awk '/Private key:/ {print $3}' <<<"$pair"); public=$(awk '/Public key:/ {print $3}' <<<"$pair")
  [[ -n "$private" && -n "$public" ]] || die 'Reality 密钥生成失败。'
  sid=$(openssl rand -hex 8); pass=$(password)
  write_config "$rp" "$tp" "$uuid" "$private" "$sid" "$sni" "$domain" "$pass"
  "$BIN" run -test -config "$CONFIG"
  write_unit; systemctl enable --now "$UNIT"
  write_connections "$rp" "$tp" "$uuid" "$public" "$sid" "$sni" "$domain" "$pass"
  info '完成。请自行在服务商安全组和防火墙放行 TCP 443、8443；Certbot 续期需要 TCP 80。'
  show_node
}

status_node() { [[ -f "$CONFIG" ]] || die '未安装。'; "$BIN" run -test -config "$CONFIG"; systemctl --no-pager --full status "$UNIT" || true; ss -lntp | grep -E ':(443|8443)[[:space:]]' || true; }
show_node() { [[ -f "$CONNECTIONS" ]] || die '未找到连接信息。'; cat "$CONNECTIONS"; }
update_node() { [[ -f "$CONFIG" ]] || die '未安装。'; install_xray; "$BIN" run -test -config "$CONFIG"; systemctl restart "$UNIT"; info 'Xray 已更新。'; }

backup_node() {
  local out="${1:-}" file
  [[ -d "$out" && -f "$CONFIG" ]] || die '用法：backup <存在的目录>。'
  file="$out/$APP-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -C /etc --exclude='surge-node/tls' -czf "$file" surge-node; chmod 0600 "$file"
  info "备份已生成：$file（不含 TLS 私钥）。"
}

uninstall_node() {
  [[ -f "$CONFIG" ]] || die '未安装。'
  read -r -p '确认删除本脚本的服务、Xray 和 /etc/surge-node？[y/N] ' answer
  [[ "$answer" =~ ^[yY]$ ]] || { info '已取消。'; return; }
  systemctl disable --now "$UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT.service" /etc/letsencrypt/renewal-hooks/deploy/surge-node "$BIN"
  rm -rf "$DIR"; systemctl daemon-reload; userdel "$USER" 2>/dev/null || true
  info '已卸载。Certbot 与已签发证书保留，避免误删其他服务。'
}

main() {
  case "${1:-}" in
    -h|--help|help|'') usage; return ;;
  esac
  root
  case "${1:-}" in
    install) install_node ;; status) status_node ;; show) show_node ;; update) update_node ;;
    backup) backup_node "${2:-}" ;; uninstall) uninstall_node ;; -h|--help|help|'') usage ;;
    *) die "未知命令：$1" ;;
  esac
}
main "$@"
