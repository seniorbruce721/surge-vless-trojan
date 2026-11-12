#!/usr/bin/env bash
# Personal VLESS + REALITY + XTLS Vision installer for Debian/Ubuntu.
# Does not manage Snell, Trojan, SSH, BBR, sysctl or firewall rules.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly APP='vless-node'
readonly UNIT='vless-node'
readonly USER='vless-node'
if [[ "${VLESS_NODE_NO_MAIN:-0}" == 1 && "${VLESS_NODE_TEST_MODE:-0}" == 1 ]]; then
  readonly DIR="${VLESS_NODE_DIR:-/etc/vless-node}"
  readonly BIN_DIR="${VLESS_NODE_BIN_DIR:-/usr/local/lib/vless-node}"
  readonly UNIT_DIR="${VLESS_NODE_UNIT_DIR:-/etc/systemd/system}"
else
  readonly DIR='/etc/vless-node'
  readonly BIN_DIR='/usr/local/lib/vless-node'
  readonly UNIT_DIR='/etc/systemd/system'
fi
readonly BIN="$BIN_DIR/xray"
readonly UNIT_FILE="$UNIT_DIR/$UNIT.service"
readonly CONFIG="$DIR/config.json"
readonly META="$DIR/meta.env"
readonly CONNECTIONS="$DIR/connections.txt"
readonly PREVIOUS="$DIR/xray.previous"
readonly OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
root() { [[ ${EUID:-999} -eq 0 ]] || die '请使用 root 或 sudo 运行。'; }

usage() {
  cat <<'EOF'
用法：vless-node.sh <命令>
  install     安装 VLESS + REALITY + XTLS Vision
  show        显示敏感节点信息和 Surge [Proxy] 配置
  update      校验并更新本工具管理的 Xray
  status      检查配置、服务与 IPv4/IPv6 监听
  uninstall   删除本脚本管理的服务和文件

脚本不修改防火墙、SSH、BBR、Snell 或 Trojan。
EOF
}

require_supported_host() {
  local os_id version pretty
  [[ "$(uname -s)" == Linux ]] || die '仅支持 Linux。'
  command -v systemctl >/dev/null 2>&1 || die '需要 systemd；当前系统未找到 systemctl。'
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "不支持的 CPU 架构：$(uname -m)；仅支持 x86_64/aarch64。" ;; esac
  [[ -r "$OS_RELEASE_FILE" ]] || die "无法读取 $OS_RELEASE_FILE。"
  # /etc/os-release is supplied by the operating system.
  # shellcheck disable=SC1090
  source "$OS_RELEASE_FILE"
  os_id=${ID:-}; version=${VERSION_ID:-}; pretty=${PRETTY_NAME:-未知}
  case "$os_id:$version" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) die "仅支持 Debian 12/13 和 Ubuntu 22.04/24.04；当前：$pretty" ;;
  esac
}

network_mode_from_capabilities() {
  local ipv4="$1" ipv6="$2" single_dual="$3"
  if [[ "$ipv4" == yes && "$ipv6" == yes ]]; then
    [[ "$single_dual" == yes ]] && printf 'dual-single' || printf 'dual-split'
  elif [[ "$ipv4" == yes ]]; then
    printf 'ipv4'
  elif [[ "$ipv6" == yes ]]; then
    printf 'ipv6'
  else
    die '未检测到可用的公网 IPv4 或 IPv6。'
  fi
}

render_inbound() {
  local tag="$1" listen="$2" port="$3" uuid="$4" private="$5" sid="$6" sni="$7"
  printf '%s' "{\"tag\":\"$tag\",\"listen\":\"$listen\",\"port\":$port,\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"$uuid\",\"flow\":\"xtls-rprx-vision\"}],\"decryption\":\"none\"},\"streamSettings\":{\"method\":\"raw\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"target\":\"$sni:443\",\"xver\":0,\"serverNames\":[\"$sni\"],\"privateKey\":\"$private\",\"shortIds\":[\"$sid\"]}}}"
}

render_config() {
  local mode="$1" port="$2" uuid="$3" private="$4" sid="$5" sni="$6"
  printf '{\n  "log":{"loglevel":"warning"},\n  "inbounds":[\n    '
  case "$mode" in
    ipv4) render_inbound 'vless-reality-v4' '0.0.0.0' "$port" "$uuid" "$private" "$sid" "$sni" ;;
    ipv6|dual-single) render_inbound 'vless-reality-v6' '::' "$port" "$uuid" "$private" "$sid" "$sni" ;;
    dual-split)
      render_inbound 'vless-reality-v4' '0.0.0.0' "$port" "$uuid" "$private" "$sid" "$sni"
      printf ',\n    '
      render_inbound 'vless-reality-v6' '::' "$port" "$uuid" "$private" "$sid" "$sni"
      ;;
    *) die "未知监听模式：$mode" ;;
  esac
  printf '\n  ],\n  "outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]\n}\n'
}

surge_line() {
  local name="$1" host="$2" port="$3" uuid="$4" public="$5" sid="$6" sni="$7" ip_version="${8:-}"
  printf '%s = vless, %s, %s, username=%s, flow=xtls-rprx-vision, sni=%s, reality-public-key=%s, reality-short-id=%s' \
    "$name" "$host" "$port" "$uuid" "$sni" "$public" "$sid"
  [[ -z "$ip_version" ]] || printf ', ip-version=%s' "$ip_version"
}

render_connection_info() {
  local ipv4="$1" ipv6="$2" domain="$3" domain_ip_version="$4" port="$5"
  local uuid="$6" public="$7" sid="$8" sni="$9"
  printf '# 敏感信息：不要上传、截图或分享。\n'
  [[ -z "$ipv4" ]] || printf '服务器 IPv4：%s\n' "$ipv4"
  [[ -z "$ipv6" ]] || printf '服务器 IPv6：%s\n' "$ipv6"
  [[ -z "$domain" ]] || printf '服务器域名：%s\n' "$domain"
  printf '端口：%s\nUUID：%s\nSNI：%s\nREALITY Public Key：%s\nShort ID：%s\n' \
    "$port" "$uuid" "$sni" "$public" "$sid"
  printf '\n# Surge [Proxy] / Proxy.dconf\n'
  if [[ -n "$ipv4" ]]; then surge_line 'Personal-VLESS-IPv4' "$ipv4" "$port" "$uuid" "$public" "$sid" "$sni"; printf '\n'; fi
  if [[ -n "$ipv6" ]]; then surge_line 'Personal-VLESS-IPv6' "$ipv6" "$port" "$uuid" "$public" "$sid" "$sni"; printf '\n'; fi
  if [[ -n "$domain" && -n "$domain_ip_version" ]]; then
    surge_line 'Personal-VLESS-Domain' "$domain" "$port" "$uuid" "$public" "$sid" "$sni" "$domain_ip_version"
    printf '\n'
  fi
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_domain() {
  [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
interactive_terminal() { [[ -t 0 && -t 1 ]]; }

ask() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    printf '%s [%s]：' "$prompt" "$default" >/dev/tty
  else
    printf '%s：' "$prompt" >/dev/tty
  fi
  IFS= read -r value </dev/tty || die '无法读取输入。'
  printf '%s' "${value:-$default}"
}

arch_asset_name() {
  case "$(uname -m)" in
    x86_64) printf 'Xray-linux-64.zip' ;;
    aarch64) printf 'Xray-linux-arm64-v8a.zip' ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

release_asset() {
  local repo="$1" asset="$2" release url digest
  release=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    "https://api.github.com/repos/$repo/releases/latest") || return 1
  url=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url // empty' \
    <<<"$release" | head -n1)
  digest=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest // empty' \
    <<<"$release" | head -n1)
  [[ -n "$url" && "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s|%s\n' "$url" "${digest#sha256:}"
}

install_dependencies() {
  local packages=(ca-certificates curl jq openssl unzip iproute2 netcat-openbsd)
  local missing=() package
  for package in curl jq openssl unzip ip ss nc; do
    command -v "$package" >/dev/null 2>&1 || missing+=("$package")
  done
  ((${#missing[@]} == 0)) && return
  info "补齐必要依赖：${packages[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}

download_xray_to() {
  local destination="$1" asset pair url digest archive actual tmp
  asset=$(arch_asset_name)
  tmp=$(mktemp -d)
  archive="$tmp/$asset"
  pair=$(release_asset XTLS/Xray-core "$asset") || {
    rm -rf "$tmp"; die '官方 Release 未提供匹配架构且可校验的 SHA-256 digest，已拒绝安装。';
  }
  url=${pair%%|*}; digest=${pair##*|}
  curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$archive" || {
    rm -rf "$tmp"; die 'Xray 官方安装包下载失败。';
  }
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
  fi
  [[ "${actual,,}" == "${digest,,}" ]] || {
    rm -rf "$tmp"; die 'Xray 安装包 SHA-256 校验失败。';
  }
  unzip -qq "$archive" xray -d "$tmp/unpacked"
  install -m 0755 "$tmp/unpacked/xray" "$destination"
  "$destination" version >/dev/null
  rm -rf "$tmp"
}

trace_public_ip() {
  local family="$1" output ip_value
  output=$(curl "-$family" -fsS --connect-timeout 5 --max-time 10 \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || return 1
  ip_value=$(awk -F= '$1 == "ip" {print $2; exit}' <<<"$output")
  [[ -n "$ip_value" ]] || return 1
  printf '%s' "$ip_value"
}

collect_network_state() {
  PUBLIC_IPV4=''; PUBLIC_IPV6=''
  IPV4_PUBLIC=no; IPV6_PUBLIC=no
  IPV4_REASON='IPv4 HTTPS 出站探测失败或无 IPv4 路由'
  IPV6_REASON='IPv6 HTTPS 出站探测失败或无 IPv6 路由'
  if PUBLIC_IPV4=$(trace_public_ip 4); then IPV4_PUBLIC=yes; IPV4_REASON=ok; fi
  if PUBLIC_IPV6=$(trace_public_ip 6); then IPV6_PUBLIC=yes; IPV6_REASON=ok; fi
}

port_is_free() {
  local port="$1" listeners
  if ! listeners=$(ss -H -ltn 2>&1); then
    die "无法检查 TCP 端口 $port 是否被占用；ss 执行失败：${listeners:-未知错误}"
  fi
  ! awk -v p=":$port" '$4 ~ p "$" {found=1} END {exit !found}' <<<"$listeners"
}

validate_sni_target() {
  local candidate="$1" sni="$2"
  valid_domain "$sni" || die 'SNI 必须是有效域名，不能填写 IP。'
  "$candidate" tls ping "$sni:443" >/dev/null 2>&1 || \
    die "SNI 目标 $sni:443 未通过 Xray TLS 探测；请换用你已验证的直连 TLS 1.3 域名。"
}

generate_identity() {
  local candidate="$1" keys
  UUID=$("$candidate" uuid)
  keys=$("$candidate" x25519)
  PRIVATE_KEY=$(awk -F ':' '/^Private ?[Kk]ey:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$keys")
  PUBLIC_KEY=$(awk -F ':' '/^(Public ?[Kk]ey|Password|Password \(PublicKey\)):/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$keys")
  SHORT_ID=$(openssl rand -hex 8)
  [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || \
    die 'Xray 身份信息生成失败。'
}

connection_probe() {
  local family="$1" port="$2"
  if [[ "$family" == 4 ]]; then
    nc -4 -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1
  else
    nc -6 -z -w 1 ::1 "$port" >/dev/null 2>&1
  fi
}

probe_candidate_mode() {
  local mode="$1" candidate="$2" port="$3" uuid="$4" private="$5" sid="$6" sni="$7"
  local tmp config pid ok=no attempt
  tmp=$(mktemp -d); config="$tmp/config.json"
  render_config "$mode" "$port" "$uuid" "$private" "$sid" "$sni" >"$config"
  if ! "$candidate" run -test -config "$config" >/dev/null 2>&1; then rm -rf "$tmp"; return 1; fi
  "$candidate" run -config "$config" >"$tmp/xray.log" 2>&1 & pid=$!
  for attempt in 1 2 3 4 5; do
    if kill -0 "$pid" 2>/dev/null; then
      case "$mode" in
        ipv4) connection_probe 4 "$port" && ok=yes ;;
        ipv6) connection_probe 6 "$port" && ok=yes ;;
        dual-single|dual-split) connection_probe 4 "$port" && connection_probe 6 "$port" && ok=yes ;;
      esac
    fi
    [[ "$ok" == yes ]] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$tmp"
  [[ "$ok" == yes ]]
}

choose_validated_listen_mode() {
  local ipv4="$1" ipv6="$2" candidate="$3" port="$4" uuid="$5" private="$6" sid="$7" sni="$8"
  local mode
  if [[ "$ipv4" == yes && "$ipv6" == yes ]]; then
    for mode in dual-single dual-split; do
      if probe_candidate_mode "$mode" "$candidate" "$port" "$uuid" "$private" "$sid" "$sni"; then printf '%s' "$mode"; return; fi
    done
  elif [[ "$ipv4" == yes ]]; then
    probe_candidate_mode ipv4 "$candidate" "$port" "$uuid" "$private" "$sid" "$sni" && { printf ipv4; return; }
  elif [[ "$ipv6" == yes ]]; then
    probe_candidate_mode ipv6 "$candidate" "$port" "$uuid" "$private" "$sid" "$sni" && { printf ipv6; return; }
  fi
  die '候选 Xray 未通过实际 IPv4/IPv6 本地监听测试。'
}

domain_ip_version() {
  local domain="$1" ipv4="$2" ipv6="$3" v4_match=no v6_match=no
  [[ -n "$domain" ]] || return 0
  valid_domain "$domain" || return 1
  if [[ -n "$ipv4" ]] && getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -Fqx "$ipv4"; then v4_match=yes; fi
  if [[ -n "$ipv6" ]] && getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | grep -Fqx "$ipv6"; then v6_match=yes; fi
  if [[ "$v4_match" == yes && "$v6_match" == yes ]]; then printf dual
  elif [[ "$v4_match" == yes ]]; then printf v4-only
  elif [[ "$v6_match" == yes ]]; then printf v6-only
  else return 1
  fi
}

meta_value() { awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$META"; }

write_metadata() {
  cat >"$META" <<EOF
MANAGED_BY=vless-node.sh
UUID=$UUID
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
PORT=$PORT
LISTEN_MODE=$LISTEN_MODE
PUBLIC_IPV4=$PUBLIC_IPV4
PUBLIC_IPV6=$PUBLIC_IPV6
DOMAIN=$DOMAIN
DOMAIN_IP_VERSION=$DOMAIN_IP_VERSION
EOF
}

write_connections() {
  render_connection_info "$PUBLIC_IPV4" "$PUBLIC_IPV6" "$DOMAIN" "$DOMAIN_IP_VERSION" \
    "$PORT" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SNI" >"$CONNECTIONS"
}

write_unit() {
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Personal VLESS REALITY Xray service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
Group=$USER
ExecStart=$BIN run -config $CONFIG
Restart=on-failure
RestartSec=3s
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$UNIT_FILE"
}

ensure_service_user() {
  if getent passwd "$USER" >/dev/null 2>&1; then die "系统账户 $USER 已存在，拒绝接管。"; fi
  useradd --system --home-dir "$DIR" --no-create-home --shell /usr/sbin/nologin "$USER"
}

ensure_install_target_free() {
  [[ ! -e "$DIR" ]] || die "配置目录已存在：$DIR"
  [[ ! -e "$BIN_DIR" ]] || die "程序目录已存在：$BIN_DIR"
  [[ ! -e "$UNIT_FILE" ]] || die "systemd unit 已存在：$UNIT_FILE"
  getent passwd "$USER" >/dev/null 2>&1 && die "系统账户已存在：$USER"
  return 0
}

wait_for_runtime() {
  local mode="$1" port="$2" attempt restarts
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet "$UNIT"; then
      case "$mode" in
        ipv4) connection_probe 4 "$port" && break ;;
        ipv6) connection_probe 6 "$port" && break ;;
        dual-single|dual-split) connection_probe 4 "$port" && connection_probe 6 "$port" && break ;;
      esac
    fi
    sleep 1
  done
  systemctl is-active --quiet "$UNIT" || return 1
  case "$mode" in
    ipv4) connection_probe 4 "$port" || return 1 ;;
    ipv6) connection_probe 6 "$port" || return 1 ;;
    dual-single|dual-split) connection_probe 4 "$port" && connection_probe 6 "$port" || return 1 ;;
  esac
  restarts=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || printf unknown)
  [[ "$restarts" == 0 ]]
}

firewall_report() {
  local port="$1"
  printf '\n防火墙只读检查（脚本未修改规则）：\n'
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose 2>/dev/null || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --state 2>/dev/null || true
    firewall-cmd --query-port="$port/tcp" 2>/dev/null || true
  elif command -v nft >/dev/null 2>&1; then
    nft list ruleset 2>/dev/null | grep -E "(tcp dport|dport).*${port}" || printf '未能确认 TCP %s 放行，请人工检查。\n' "$port"
  else
    printf '未找到可识别的防火墙前端，请人工检查 TCP %s 及云安全组。\n' "$port"
  fi
}

cleanup_failed_install() {
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  rm -rf "$DIR" "$BIN_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  getent passwd "$USER" >/dev/null 2>&1 && userdel "$USER" >/dev/null 2>&1 || true
}

install_exit_cleanup() {
  local status=$?
  trap - EXIT
  [[ -z "${INSTALL_TMP:-}" ]] || rm -rf "$INSTALL_TMP"
  if [[ "${INSTALL_RESOURCES_CREATED:-no}" == yes && "${INSTALL_COMMITTED:-no}" != yes ]]; then
    cleanup_failed_install
  fi
  exit "$status"
}

install_node() {
  local tmp candidate config_candidate domain_version
  INSTALL_TMP=''; INSTALL_RESOURCES_CREATED=no; INSTALL_COMMITTED=no
  require_supported_host
  ensure_install_target_free
  interactive_terminal || die 'install 必须在交互式终端执行，避免敏感节点信息进入日志。'
  install_dependencies
  tmp=$(mktemp -d); candidate="$tmp/xray"; config_candidate="$tmp/config.json"
  INSTALL_TMP=$tmp
  trap install_exit_cleanup EXIT
  download_xray_to "$candidate"
  collect_network_state
  [[ "$IPV4_PUBLIC" == yes || "$IPV6_PUBLIC" == yes ]] || {
    rm -rf "$tmp"; die "没有可验证的公网地址族。IPv4：$IPV4_REASON；IPv6：$IPV6_REASON";
  }
  PORT=$(ask '监听端口' 443)
  valid_port "$PORT" || { rm -rf "$tmp"; die '端口必须是 1-65535 的整数。'; }
  port_is_free "$PORT" || { rm -rf "$tmp"; die "TCP 端口 $PORT 已被占用。"; }
  SNI=$(ask 'REALITY 目标 SNI（必须是你已验证的域名，无默认值）')
  validate_sni_target "$candidate" "$SNI"
  DOMAIN=$(ask '连接域名（可留空，须解析到本机公网地址）')
  generate_identity "$candidate"
  LISTEN_MODE=$(choose_validated_listen_mode "$IPV4_PUBLIC" "$IPV6_PUBLIC" "$candidate" "$PORT" \
    "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$SNI")
  render_config "$LISTEN_MODE" "$PORT" "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$SNI" >"$config_candidate"
  "$candidate" run -test -config "$config_candidate" >/dev/null 2>&1 || { rm -rf "$tmp"; die '最终 Xray 配置校验失败。'; }
  DOMAIN_IP_VERSION=''
  if [[ -n "$DOMAIN" ]]; then
    if domain_version=$(domain_ip_version "$DOMAIN" "$PUBLIC_IPV4" "$PUBLIC_IPV6"); then
      DOMAIN_IP_VERSION=$domain_version
    else
      printf '警告：连接域名未匹配本机已验证公网地址，不生成域名版 Surge 节点。\n' >&2
      DOMAIN=''
    fi
  fi
  port_is_free "$PORT" || { rm -rf "$tmp"; die "TCP 端口 $PORT 已被占用，安装已停止。"; }
  ensure_service_user
  INSTALL_RESOURCES_CREATED=yes
  mkdir -p "$DIR" "$BIN_DIR" "$UNIT_DIR"
  chmod 0750 "$DIR"; chmod 0755 "$BIN_DIR"
  install -m 0755 "$candidate" "$BIN"
  install -m 0640 "$config_candidate" "$CONFIG"
  write_metadata; write_connections
  chmod 0640 "$META" "$CONNECTIONS"
  chown -R root:"$USER" "$DIR"
  chown -R root:root "$BIN_DIR"
  write_unit
  if ! systemctl daemon-reload || ! systemctl enable --now "$UNIT" || ! wait_for_runtime "$LISTEN_MODE" "$PORT"; then
    die '服务启动或本地监听验证失败；已清理本次安装资源。'
  fi
  firewall_report "$PORT"
  INSTALL_COMMITTED=yes
  rm -rf "$tmp"; INSTALL_TMP=''
  trap - EXIT
  printf '\n安装成功。本地服务已验证；公网入站仍需在 Surge 上实测，并确认云安全组/防火墙已放行 TCP %s。\n\n' "$PORT"
  render_connection_info "$PUBLIC_IPV4" "$PUBLIC_IPV6" "$DOMAIN" "$DOMAIN_IP_VERSION" \
    "$PORT" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SNI"
}

load_metadata() {
  [[ -r "$META" ]] || die "未找到连接元数据：$META"
  [[ "$(meta_value MANAGED_BY)" == vless-node.sh ]] || die '连接元数据缺少本脚本所有权标记，拒绝继续。'
  UUID=$(meta_value UUID); PUBLIC_KEY=$(meta_value PUBLIC_KEY); SHORT_ID=$(meta_value SHORT_ID)
  SNI=$(meta_value SNI); PORT=$(meta_value PORT); LISTEN_MODE=$(meta_value LISTEN_MODE)
  PUBLIC_IPV4=$(meta_value PUBLIC_IPV4); PUBLIC_IPV6=$(meta_value PUBLIC_IPV6)
  DOMAIN=$(meta_value DOMAIN); DOMAIN_IP_VERSION=$(meta_value DOMAIN_IP_VERSION)
  [[ -n "$UUID" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" && -n "$SNI" && -n "$PORT" && -n "$LISTEN_MODE" ]] || \
    die '连接元数据不完整，拒绝猜测或覆盖。'
}

show_node() {
  interactive_terminal || die 'show 只允许在交互式终端显示，避免 UUID 和密钥进入日志。'
  load_metadata
  render_connection_info "$PUBLIC_IPV4" "$PUBLIC_IPV6" "$DOMAIN" "$DOMAIN_IP_VERSION" \
    "$PORT" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SNI"
}

status_node() {
  [[ -x "$BIN" && -r "$CONFIG" ]] || die '未找到本脚本管理的完整安装。'
  load_metadata
  "$BIN" run -test -config "$CONFIG" >/dev/null && printf '配置：有效\n' || printf '配置：无效\n'
  printf '服务：%s\n' "$(systemctl is-active "$UNIT" 2>/dev/null || true)"
  printf '开机启动：%s\n' "$(systemctl is-enabled "$UNIT" 2>/dev/null || true)"
  printf 'NRestarts：%s\n' "$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || printf unknown)"
  printf '监听模式：%s\n' "$LISTEN_MODE"
  case "$LISTEN_MODE" in
    ipv4) connection_probe 4 "$PORT" && printf 'IPv4 本地监听：OK\n' || printf 'IPv4 本地监听：失败\n' ;;
    ipv6) connection_probe 6 "$PORT" && printf 'IPv6 本地监听：OK\n' || printf 'IPv6 本地监听：失败\n' ;;
    dual-single|dual-split)
      connection_probe 4 "$PORT" && printf 'IPv4 本地监听：OK\n' || printf 'IPv4 本地监听：失败\n'
      connection_probe 6 "$PORT" && printf 'IPv6 本地监听：OK\n' || printf 'IPv6 本地监听：失败\n'
      ;;
  esac
}

update_node() {
  local tmp candidate
  require_supported_host
  [[ -x "$BIN" && -r "$CONFIG" && -r "$META" && -f "$UNIT_FILE" ]] || die '未找到本脚本管理的完整安装。'
  install_dependencies
  load_metadata
  tmp=$(mktemp -d); candidate="$tmp/xray"
  download_xray_to "$candidate"
  "$candidate" run -test -config "$CONFIG" >/dev/null 2>&1 || { rm -rf "$tmp"; die '新 Xray 无法验证现有配置，未做替换。'; }
  cp -p "$BIN" "$PREVIOUS"
  install -m 0755 "$candidate" "$BIN"
  rm -rf "$tmp"
  if systemctl restart "$UNIT" && wait_for_runtime "$LISTEN_MODE" "$PORT"; then
    rm -f "$PREVIOUS"
    info 'Xray 更新成功；UUID、密钥、端口、SNI 和监听模式均未改变。'
    return
  fi
  install -m 0755 "$PREVIOUS" "$BIN"
  rm -f "$PREVIOUS"
  systemctl restart "$UNIT" >/dev/null 2>&1 || true
  if wait_for_runtime "$LISTEN_MODE" "$PORT"; then
    die '新 Xray 启动验证失败；已恢复旧 Xray 和旧服务。'
  fi
  die '新 Xray 启动验证失败，旧二进制已恢复，但旧服务也未恢复；请检查 journalctl。'
}

uninstall_node() {
  local answer
  [[ -e "$DIR" || -e "$BIN_DIR" || -e "$UNIT_FILE" ]] || die '未找到本脚本管理的安装。'
  [[ -r "$META" && "$(meta_value MANAGED_BY)" == vless-node.sh ]] || \
    die '未找到 vless-node.sh 所有权标记，拒绝删除同名资源。'
  printf '仅删除 vless-node 自有服务、配置和程序，确认继续？[y/N]：'
  IFS= read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || { info '已取消。'; return; }
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  rm -rf "$DIR" "$BIN_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  getent passwd "$USER" >/dev/null 2>&1 && userdel "$USER" >/dev/null 2>&1 || true
  info '卸载完成；未修改 Snell、Trojan、SSH、BBR 或防火墙。'
}

main() {
  case "${1:-}" in
    -h|--help|help|'') usage; return ;;
  esac
  root
  case "${1:-}" in
    install) install_node ;;
    show) show_node ;;
    update) update_node ;;
    status) status_node ;;
    uninstall) uninstall_node ;;
    *) die "未知命令：$1" ;;
  esac
}

[[ "${VLESS_NODE_NO_MAIN:-0}" == 1 ]] || main "$@"
