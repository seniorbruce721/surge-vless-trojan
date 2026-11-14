#!/usr/bin/env bash
# Independent VLESS + XHTTP + REALITY test installer for Debian/Ubuntu.
# It never manages Snell, the existing VLESS/Trojan services, SSH, BBR or firewall rules.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly APP='vless-xhttp-node'
if [[ "${VLESS_XHTTP_NO_MAIN:-0}" == 1 && "${VLESS_XHTTP_TEST_MODE:-0}" == 1 ]]; then
  readonly BASE_DIR="${VLESS_XHTTP_BASE_DIR:-/etc/vless-xhttp-node}"
  readonly BASE_BIN_DIR="${VLESS_XHTTP_BASE_BIN_DIR:-/usr/local/lib/vless-xhttp-node}"
  readonly UNIT_DIR="${VLESS_XHTTP_UNIT_DIR:-/etc/systemd/system}"
else
  readonly BASE_DIR='/etc/vless-xhttp-node'
  readonly BASE_BIN_DIR='/usr/local/lib/vless-xhttp-node'
  readonly UNIT_DIR='/etc/systemd/system'
fi
readonly OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

PROFILE=''; UNIT=''; USER=''; DIR=''; BIN_DIR=''; BIN=''; UNIT_FILE=''
CONFIG=''; META=''; CONNECTIONS=''; DEFAULT_PORT=''

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
root() { [[ ${EUID:-999} -eq 0 ]] || die '请使用 root 或 sudo 运行。'; }

usage() {
  cat <<'EOF'
用法：vless-xhttp-node.sh <命令> <模式>
  install plain          安装 VLESS + XHTTP + REALITY
  install encryption     另装启用 mlkem768x25519plus 的测试实例
  show plain|encryption  显示该实例的敏感连接信息
  status plain|encryption
  uninstall plain|encryption

两个模式使用不同服务、目录、账户和默认端口，可以并行测试。
脚本不修改防火墙、SSH、BBR、Snell、现有 VLESS 或 Trojan。
EOF
}

select_profile() {
  PROFILE="${1:-}"
  case "$PROFILE" in
    plain)
      UNIT='vless-xhttp-plain.service'; USER='vless-xhttp-plain'; DEFAULT_PORT=24443 ;;
    encryption)
      UNIT='vless-xhttp-encryption.service'; USER='vless-xhttp-encryption'; DEFAULT_PORT=24444 ;;
    *) die '模式必须是 plain 或 encryption。' ;;
  esac
  DIR="$BASE_DIR/$PROFILE"
  BIN_DIR="$BASE_BIN_DIR/$PROFILE"
  BIN="$BIN_DIR/xray"
  UNIT_FILE="$UNIT_DIR/$UNIT"
  CONFIG="$DIR/config.json"
  META="$DIR/meta.env"
  CONNECTIONS="$DIR/connections.txt"
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
    debian:12|debian:13|ubuntu:24.04|ubuntu:26.04) ;;
    *) die "仅支持 Debian 12/13 和 Ubuntu 24.04/26.04；当前：$pretty" ;;
  esac
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_domain() { [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
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

install_dependencies() {
  local packages=(ca-certificates curl jq openssl unzip iproute2 netcat-openbsd)
  local missing=() command_name
  for command_name in curl jq openssl unzip ip ss nc; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  ((${#missing[@]} == 0)) && return
  info "补齐必要依赖：${packages[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
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
  [[ "$(jq -r '.draft, .prerelease' <<<"$release")" == $'false\nfalse' ]] || return 1
  url=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url // empty' \
    <<<"$release" | head -n1)
  digest=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest // empty' \
    <<<"$release" | head -n1)
  [[ -n "$url" && "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s|%s\n' "$url" "${digest#sha256:}"
}

download_xray_to() {
  local destination="$1" asset pair url digest archive actual tmp
  asset=$(arch_asset_name); tmp=$(mktemp -d); archive="$tmp/$asset"
  pair=$(release_asset XTLS/Xray-core "$asset") || {
    rm -rf "$tmp"; die '官方稳定 Release 未提供匹配架构且可校验的 SHA-256 digest，已拒绝安装。';
  }
  url=${pair%%|*}; digest=${pair##*|}
  curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$archive" || {
    rm -rf "$tmp"; die 'Xray 官方安装包下载失败。';
  }
  actual=$(sha256sum "$archive" | awk '{print $1}')
  [[ "${actual,,}" == "${digest,,}" ]] || { rm -rf "$tmp"; die 'Xray 安装包 SHA-256 校验失败。'; }
  unzip -qq "$archive" xray -d "$tmp/unpacked"
  install -m 0755 "$tmp/unpacked/xray" "$destination"
  "$destination" version >/dev/null
  rm -rf "$tmp"
}

render_inbound() {
  local tag="$1" listen="$2" port="$3" uuid="$4" private="$5" sid="$6"
  local sni="$7" path="$8" decryption="$9"
  jq -cn \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg uuid "$uuid" \
    --arg private "$private" --arg sid "$sid" --arg sni "$sni" --arg path "$path" \
    --arg decryption "$decryption" \
    '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:""}],decryption:$decryption},streamSettings:{network:"xhttp",xhttpSettings:{path:$path},security:"reality",realitySettings:{show:false,target:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$private,shortIds:[$sid]}}}'
}

render_config() {
  local mode="$1" port="$2" uuid="$3" private="$4" sid="$5" sni="$6" path="$7" decryption="$8"
  local first second
  case "$mode" in
    ipv4) first=$(render_inbound 'vless-xhttp-v4' '0.0.0.0' "$port" "$uuid" "$private" "$sid" "$sni" "$path" "$decryption"); jq -cn --argjson first "$first" '{log:{loglevel:"warning"},inbounds:[$first],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' ;;
    ipv6|dual-single) first=$(render_inbound 'vless-xhttp-v6' '::' "$port" "$uuid" "$private" "$sid" "$sni" "$path" "$decryption"); jq -cn --argjson first "$first" '{log:{loglevel:"warning"},inbounds:[$first],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' ;;
    dual-split)
      first=$(render_inbound 'vless-xhttp-v4' '0.0.0.0' "$port" "$uuid" "$private" "$sid" "$sni" "$path" "$decryption")
      second=$(render_inbound 'vless-xhttp-v6' '::' "$port" "$uuid" "$private" "$sid" "$sni" "$path" "$decryption")
      jq -cn --argjson first "$first" --argjson second "$second" '{log:{loglevel:"warning"},inbounds:[$first,$second],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' ;;
    *) die "未知监听模式：$mode" ;;
  esac
}

generate_identity() {
  local candidate="$1" keys
  UUID=$("$candidate" uuid)
  keys=$("$candidate" x25519)
  PRIVATE_KEY=$(awk -F ':' '/^Private ?[Kk]ey:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$keys")
  PUBLIC_KEY=$(awk -F ':' '/^(Public ?[Kk]ey|Password|Password \(PublicKey\)):/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$keys")
  SHORT_ID=$(openssl rand -hex 8)
  XHTTP_PATH="/$(openssl rand -hex 12)"
  [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && "$SHORT_ID" =~ ^[0-9a-f]{16}$ && "$XHTTP_PATH" =~ ^/[0-9a-f]{24}$ ]] || die 'Xray 身份信息生成失败。'
}

generate_vless_encryption() {
  local candidate="$1" output
  output=$("$candidate" vlessenc </dev/null) || die 'Xray vlessenc 执行失败。'
  VLESS_DECRYPTION=$(awk '
    /^Authentication: ML-KEM-768/ {selected=1; next}
    selected && /"decryption"[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*"/, ""); sub(/"[[:space:]]*$/, ""); print; exit}
  ' <<<"$output")
  VLESS_ENCRYPTION=$(awk '
    /^Authentication: ML-KEM-768/ {selected=1; next}
    selected && /"encryption"[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*"/, ""); sub(/"[[:space:]]*$/, ""); print; exit}
  ' <<<"$output")
  [[ "$VLESS_DECRYPTION" == mlkem768x25519plus.* && "$VLESS_ENCRYPTION" == mlkem768x25519plus.* ]] || \
    die '无法从 Xray vlessenc 的 ML-KEM-768 段取得合法参数。'
}

trace_public_ip() {
  local family="$1" output ip_value
  output=$(curl "-$family" -fsS --connect-timeout 5 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || return 1
  ip_value=$(awk -F= '$1 == "ip" {print $2; exit}' <<<"$output")
  [[ -n "$ip_value" ]] || return 1
  printf '%s' "$ip_value"
}

collect_network_state() {
  PUBLIC_IPV4=''; PUBLIC_IPV6=''; IPV4_PUBLIC=no; IPV6_PUBLIC=no
  IPV4_REASON='IPv4 HTTPS 出站探测失败或无 IPv4 路由'; IPV6_REASON='IPv6 HTTPS 出站探测失败或无 IPv6 路由'
  if PUBLIC_IPV4=$(trace_public_ip 4); then IPV4_PUBLIC=yes; IPV4_REASON=ok; fi
  if PUBLIC_IPV6=$(trace_public_ip 6); then IPV6_PUBLIC=yes; IPV6_REASON=ok; fi
}

port_is_free() {
  local port="$1" listeners
  if ! listeners=$(ss -H -ltn 2>&1); then die "无法检查 TCP 端口 $port 是否被占用；ss 执行失败：${listeners:-未知错误}"; fi
  if awk -v p=":$port" '$4 ~ p "$" {found=1} END {exit !found}' <<<"$listeners"; then
    die "TCP 端口 $port 已被占用；安装已停止，未改动现有服务。"
  fi
}

validate_sni_target() {
  local candidate="$1" sni="$2" http_version
  valid_domain "$sni" || die 'SNI 必须是有效域名，不能填写 IP。'
  "$candidate" tls ping "$sni:443" >/dev/null 2>&1 || die "SNI 目标 $sni:443 未通过 Xray TLS 探测；请更换支持 TLS 1.3 与 HTTP/2 的已验证目标。"
  http_version=$(curl -sS --http2 --tlsv1.3 --tls-max 1.3 --connect-timeout 8 --max-time 12 \
    -o /dev/null -w '%{http_version}' "https://$sni/" 2>/dev/null) || \
    die "SNI 目标 $sni:443 未通过 TLS 1.3 + HTTP/2 探测。"
  [[ "$http_version" == 2 ]] || die "SNI 目标 $sni:443 未协商 HTTP/2（实际：${http_version:-未知}）。"
}

connection_probe() {
  local family="$1" port="$2"
  if [[ "$family" == 4 ]]; then nc -4 -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1
  else nc -6 -z -w 1 ::1 "$port" >/dev/null 2>&1; fi
}

probe_candidate_mode() {
  local mode="$1" candidate="$2" port="$3" uuid="$4" private="$5" sid="$6" sni="$7" path="$8" decryption="$9"
  local tmp config pid ok=no attempt
  tmp=$(mktemp -d); config="$tmp/config.json"
  render_config "$mode" "$port" "$uuid" "$private" "$sid" "$sni" "$path" "$decryption" >"$config"
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
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$tmp"
  [[ "$ok" == yes ]]
}

choose_validated_listen_mode() {
  local ipv4="$1" ipv6="$2" candidate="$3" port="$4" uuid="$5" private="$6" sid="$7" sni="$8" path="$9" decryption="${10}"
  local mode
  if [[ "$ipv4" == yes && "$ipv6" == yes ]]; then
    for mode in dual-single dual-split; do
      if probe_candidate_mode "$mode" "$candidate" "$port" "$uuid" "$private" "$sid" "$sni" "$path" "$decryption"; then printf '%s' "$mode"; return; fi
    done
  elif [[ "$ipv4" == yes ]]; then
    probe_candidate_mode ipv4 "$candidate" "$port" "$uuid" "$private" "$sid" "$sni" "$path" "$decryption" && { printf ipv4; return; }
  elif [[ "$ipv6" == yes ]]; then
    probe_candidate_mode ipv6 "$candidate" "$port" "$uuid" "$private" "$sid" "$sni" "$path" "$decryption" && { printf ipv6; return; }
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
  else return 1; fi
}

profile_label() {
  if [[ "$1" == encryption ]]; then printf 'VLESS + XHTTP + REALITY + Encryption'; else printf 'VLESS + XHTTP + REALITY'; fi
}

render_connection_info() {
  local profile="$1" ipv4="$2" ipv6="$3" domain="$4" domain_ip_version="$5" port="$6"
  local uuid="$7" public="$8" sid="$9" sni="${10}" path="${11}" encryption="${12}"
  printf '# 敏感信息：不要上传、截图或分享。\n'
  printf '模式：%s\n' "$(profile_label "$profile")"
  [[ -z "$ipv4" ]] || printf '服务器 IPv4：%s\n' "$ipv4"
  [[ -z "$ipv6" ]] || printf '服务器 IPv6：%s\n' "$ipv6"
  [[ -z "$domain" ]] || printf '服务器域名：%s（ip-version=%s）\n' "$domain" "$domain_ip_version"
  printf '端口：%s\nUUID：%s\nSNI：%s\nREALITY Public Key：%s\nShort ID：%s\nXHTTP Path：%s\n服务端 XHTTP Mode：auto（接受客户端选择）\n客户端初始建议：stream-one\nHTTP：优先 HTTP/2\n' \
    "$port" "$uuid" "$sni" "$public" "$sid" "$path"
  if [[ "$profile" == encryption ]]; then
    printf 'VLESS Encryption：mlkem768x25519plus\n客户端 encryption：%s\n' "$encryption"
  else
    printf 'VLESS Encryption：none\n'
  fi
  cat <<'EOF'

# Surge 6.100.0 (4026)
该版本已声明支持 XHTTP、stream-one、HTTP/2 和 mlkem768x25519plus。
公开资料尚无可核验的完整 [Proxy] 参数名；以上字段须在节点编辑器或分享链接中导入验证。
状态：待客户端导入验证。脚本不会猜造 Surge 配置行，也不会修改完整 Surge 配置文件。
EOF
}

meta_value() { awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$META"; }

write_metadata() {
  cat >"$META" <<EOF
MANAGED_BY=vless-xhttp-node.sh
PROFILE=$PROFILE
UUID=$UUID
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
SNI=$SNI
XHTTP_PATH=$XHTTP_PATH
VLESS_ENCRYPTION=$VLESS_ENCRYPTION
PORT=$PORT
LISTEN_MODE=$LISTEN_MODE
PUBLIC_IPV4=$PUBLIC_IPV4
PUBLIC_IPV6=$PUBLIC_IPV6
DOMAIN=$DOMAIN
DOMAIN_IP_VERSION=$DOMAIN_IP_VERSION
EOF
}

write_connections() {
  render_connection_info "$PROFILE" "$PUBLIC_IPV4" "$PUBLIC_IPV6" "$DOMAIN" "$DOMAIN_IP_VERSION" "$PORT" \
    "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SNI" "$XHTTP_PATH" "$VLESS_ENCRYPTION" >"$CONNECTIONS"
}

write_unit() {
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Personal VLESS XHTTP REALITY ($PROFILE)
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

ensure_install_target_free() {
  [[ ! -e "$DIR" ]] || die "配置目录已存在：$DIR"
  [[ ! -e "$BIN_DIR" ]] || die "程序目录已存在：$BIN_DIR"
  [[ ! -e "$UNIT_FILE" ]] || die "systemd unit 已存在：$UNIT_FILE"
  getent passwd "$USER" >/dev/null 2>&1 && die "系统账户已存在：$USER"
  return 0
}

ensure_service_user() {
  getent passwd "$USER" >/dev/null 2>&1 && die "系统账户 $USER 已存在，拒绝接管。"
  useradd --system --home-dir "$DIR" --no-create-home --shell /usr/sbin/nologin "$USER"
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
  if command -v ufw >/dev/null 2>&1; then ufw status verbose 2>/dev/null || true
  elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --state 2>/dev/null || true; firewall-cmd --query-port="$port/tcp" 2>/dev/null || true
  elif command -v nft >/dev/null 2>&1; then nft list ruleset 2>/dev/null | grep -E "(tcp dport|dport).*${port}" || printf '未能确认 TCP %s 放行，请人工检查。\n' "$port"
  else printf '未找到可识别的防火墙前端，请人工检查 TCP %s 及云安全组。\n' "$port"; fi
}

cleanup_failed_install() {
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"; rm -rf "$DIR" "$BIN_DIR"
  rmdir "$BASE_DIR" "$BASE_BIN_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  getent passwd "$USER" >/dev/null 2>&1 && userdel "$USER" >/dev/null 2>&1 || true
}

install_exit_cleanup() {
  local status=$?
  trap - EXIT
  [[ -z "${INSTALL_TMP:-}" ]] || rm -rf "$INSTALL_TMP"
  if [[ "${INSTALL_RESOURCES_CREATED:-no}" == yes && "${INSTALL_COMMITTED:-no}" != yes ]]; then cleanup_failed_install; fi
  exit "$status"
}

install_node() {
  local tmp candidate config_candidate domain_version
  INSTALL_TMP=''; INSTALL_RESOURCES_CREATED=no; INSTALL_COMMITTED=no
  require_supported_host; ensure_install_target_free
  interactive_terminal || die 'install 必须在交互式终端执行，避免敏感节点信息进入日志。'
  install_dependencies
  tmp=$(mktemp -d); candidate="$tmp/xray"; config_candidate="$tmp/config.json"; INSTALL_TMP=$tmp
  trap install_exit_cleanup EXIT
  download_xray_to "$candidate"
  collect_network_state
  [[ "$IPV4_PUBLIC" == yes || "$IPV6_PUBLIC" == yes ]] || die "没有可验证的公网地址族。IPv4：$IPV4_REASON；IPv6：$IPV6_REASON"
  PORT=$(ask '监听端口' "$DEFAULT_PORT"); valid_port "$PORT" || die '端口必须是 1-65535 的整数。'
  port_is_free "$PORT"
  SNI=$(ask 'REALITY 目标 SNI（须支持 TLS 1.3 与 HTTP/2，无默认值）'); validate_sni_target "$candidate" "$SNI"
  DOMAIN=$(ask '连接域名（可留空，须解析到本机公网地址）')
  generate_identity "$candidate"
  VLESS_DECRYPTION=none; VLESS_ENCRYPTION=none
  if [[ "$PROFILE" == encryption ]]; then generate_vless_encryption "$candidate"; fi
  LISTEN_MODE=$(choose_validated_listen_mode "$IPV4_PUBLIC" "$IPV6_PUBLIC" "$candidate" "$PORT" "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$SNI" "$XHTTP_PATH" "$VLESS_DECRYPTION")
  render_config "$LISTEN_MODE" "$PORT" "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$SNI" "$XHTTP_PATH" "$VLESS_DECRYPTION" >"$config_candidate"
  "$candidate" run -test -config "$config_candidate" >/dev/null 2>&1 || die '最终 Xray 配置校验失败。'
  DOMAIN_IP_VERSION=''
  if [[ -n "$DOMAIN" ]]; then
    if domain_version=$(domain_ip_version "$DOMAIN" "$PUBLIC_IPV4" "$PUBLIC_IPV6"); then DOMAIN_IP_VERSION=$domain_version
    else printf '警告：连接域名未匹配本机已验证公网地址，不输出域名形式。\n' >&2; DOMAIN=''; fi
  fi
  port_is_free "$PORT"
  ensure_service_user; INSTALL_RESOURCES_CREATED=yes
  mkdir -p "$DIR" "$BIN_DIR" "$UNIT_DIR"; chmod 0755 "$BASE_DIR" "$BASE_BIN_DIR" "$BIN_DIR"; chmod 0750 "$DIR"
  install -m 0755 "$candidate" "$BIN"; install -m 0640 "$config_candidate" "$CONFIG"
  write_metadata; write_connections
  chown -R root:"$USER" "$DIR"; chmod 0640 "$CONFIG"
  chown root:root "$META" "$CONNECTIONS"; chmod 0600 "$META" "$CONNECTIONS"
  chown -R root:root "$BIN_DIR"; write_unit
  if ! systemctl daemon-reload || ! systemctl enable --now "$UNIT" || ! wait_for_runtime "$LISTEN_MODE" "$PORT"; then
    die '服务启动或本地监听验证失败；将清理本次模式的安装资源。'
  fi
  firewall_report "$PORT"
  INSTALL_COMMITTED=yes; rm -rf "$tmp"; INSTALL_TMP=''; trap - EXIT
  printf '\n安装成功。本地配置和监听已验证；公网及 Surge 4026 兼容性仍需实机测试。\n\n'
  render_connection_info "$PROFILE" "$PUBLIC_IPV4" "$PUBLIC_IPV6" "$DOMAIN" "$DOMAIN_IP_VERSION" "$PORT" \
    "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SNI" "$XHTTP_PATH" "$VLESS_ENCRYPTION"
}

load_metadata() {
  [[ -r "$META" ]] || die "未找到连接元数据：$META"
  [[ "$(meta_value MANAGED_BY)" == vless-xhttp-node.sh && "$(meta_value PROFILE)" == "$PROFILE" ]] || die '所有权标记或模式不匹配，拒绝继续。'
  UUID=$(meta_value UUID); PUBLIC_KEY=$(meta_value PUBLIC_KEY); SHORT_ID=$(meta_value SHORT_ID); SNI=$(meta_value SNI)
  XHTTP_PATH=$(meta_value XHTTP_PATH); VLESS_ENCRYPTION=$(meta_value VLESS_ENCRYPTION); PORT=$(meta_value PORT); LISTEN_MODE=$(meta_value LISTEN_MODE)
  PUBLIC_IPV4=$(meta_value PUBLIC_IPV4); PUBLIC_IPV6=$(meta_value PUBLIC_IPV6); DOMAIN=$(meta_value DOMAIN); DOMAIN_IP_VERSION=$(meta_value DOMAIN_IP_VERSION)
  [[ -n "$UUID" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" && -n "$SNI" && -n "$XHTTP_PATH" && -n "$VLESS_ENCRYPTION" && -n "$PORT" && -n "$LISTEN_MODE" ]] || die '连接元数据不完整，拒绝猜测或覆盖。'
}

show_node() {
  interactive_terminal || die 'show 只允许在交互式终端显示，避免敏感信息进入日志。'
  load_metadata
  render_connection_info "$PROFILE" "$PUBLIC_IPV4" "$PUBLIC_IPV6" "$DOMAIN" "$DOMAIN_IP_VERSION" "$PORT" \
    "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SNI" "$XHTTP_PATH" "$VLESS_ENCRYPTION"
}

status_node() {
  [[ -x "$BIN" && -r "$CONFIG" ]] || die '未找到该模式的完整安装。'
  load_metadata
  "$BIN" run -test -config "$CONFIG" >/dev/null && printf '配置：有效\n' || printf '配置：无效\n'
  printf '服务：%s\n' "$(systemctl is-active "$UNIT" 2>/dev/null || true)"
  printf '开机启动：%s\n' "$(systemctl is-enabled "$UNIT" 2>/dev/null || true)"
  printf 'NRestarts：%s\n监听模式：%s\n' "$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || printf unknown)" "$LISTEN_MODE"
  case "$LISTEN_MODE" in
    ipv4) connection_probe 4 "$PORT" && printf 'IPv4 本地监听：OK\n' || printf 'IPv4 本地监听：失败\n' ;;
    ipv6) connection_probe 6 "$PORT" && printf 'IPv6 本地监听：OK\n' || printf 'IPv6 本地监听：失败\n' ;;
    dual-single|dual-split)
      connection_probe 4 "$PORT" && printf 'IPv4 本地监听：OK\n' || printf 'IPv4 本地监听：失败\n'
      connection_probe 6 "$PORT" && printf 'IPv6 本地监听：OK\n' || printf 'IPv6 本地监听：失败\n' ;;
  esac
}

uninstall_node() {
  local answer
  [[ -e "$DIR" || -e "$BIN_DIR" || -e "$UNIT_FILE" ]] || die '未找到该模式的安装。'
  [[ -r "$META" && "$(meta_value MANAGED_BY)" == vless-xhttp-node.sh && "$(meta_value PROFILE)" == "$PROFILE" ]] || die '所有权标记不匹配，拒绝删除。'
  printf '仅删除 %s 模式自有服务、配置、账户和程序，确认继续？[y/N]：' "$PROFILE"
  IFS= read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || { info '已取消。'; return; }
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"; rm -rf "$DIR" "$BIN_DIR"; rmdir "$BASE_DIR" "$BASE_BIN_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true; systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  getent passwd "$USER" >/dev/null 2>&1 && userdel "$USER" >/dev/null 2>&1 || true
  info "已卸载 ${PROFILE}；未修改另一模式、Snell、现有 VLESS/Trojan、SSH、BBR 或防火墙。"
}

main() {
  case "${1:-}" in -h|--help|help|'') usage; return ;; esac
  root; select_profile "${2:-}"
  case "${1:-}" in
    install) install_node ;;
    show) show_node ;;
    status) status_node ;;
    uninstall) uninstall_node ;;
    *) die "未知命令：$1" ;;
  esac
}

[[ "${VLESS_XHTTP_NO_MAIN:-0}" == 1 ]] || main "$@"
