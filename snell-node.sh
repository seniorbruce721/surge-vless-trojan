#!/usr/bin/env bash
# Personal Snell installer for systemd-based Linux hosts.
# Supports only official downloads currently available for Snell v4, v5 and v6.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly APP='snell-node'
readonly DIR='/etc/snell-node'
readonly BIN='/usr/local/bin/snell-server'
readonly UNIT='snell-node'
readonly USER='snell-node'
readonly CONFIG="$DIR/config.conf"
readonly META="$DIR/meta.env"
readonly CONNECTIONS="$DIR/connections.txt"
readonly PREVIOUS="$DIR/snell-server.previous"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
root() { [[ ${EUID:-999} -eq 0 ]] || die '请使用 root 或 sudo 运行。'; }

usage() {
  cat <<'EOF'
用法：snell-node.sh <命令>
  install [4|5|6]    安装 Snell；省略版本时交互选择，默认 v5
  status             显示服务和监听状态（不显示 PSK）
  show               显示敏感连接信息和 Surge [Proxy] 行
  update [4|5|6]     下载指定版本；省略时更新为当前大版本的固定官方版本
  uninstall          删除本脚本创建的服务、二进制和配置

说明：仅提供官方目前可下载的 Snell v4、v5、v6 Beta。
脚本不修改 UFW、云防火墙、sysctl、BBR 或时区。
EOF
}

is_supported_version() { [[ "$1" =~ ^[456]$ ]]; }
normalize_version() {
  case "$1" in
    4) printf '4.1.1' ;;
    5) printf '5.0.1' ;;
    6) printf '6.0.0rc2' ;;
    *) return 1 ;;
  esac
}

surge_line() {
  local version="$1" host="$2" port="$3" psk="$4" mode="$5"
  if [[ "$version" == 6 ]]; then
    printf 'Personal-Snell = snell, %s, %s, psk=%s, version=6, mode=%s, reuse=true' "$host" "$port" "$psk" "$mode"
  else
    printf 'Personal-Snell = snell, %s, %s, psk=%s, version=%s, reuse=true' "$host" "$port" "$psk" "$version"
  fi
}

ask() { local value; read -r -p "$1${2:+ [$2]}: " value; printf '%s' "${value:-$2}"; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; }
port_free() { ! ss -lnt | awk 'NR > 1 {print $4}' | grep -Eq "[:.]$1$"; }
random_psk() { openssl rand -hex 24; }

require_systemd_linux() {
  [[ "$(uname -s)" == Linux ]] || die '仅支持 Linux。'
  command -v systemctl >/dev/null 2>&1 || die '需要 systemd；当前系统不支持 systemctl。'
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "不支持的 CPU 架构：$(uname -m)；仅支持 x86_64/aarch64。" ;; esac
}

install_dependencies() {
  local missing=() command pkg_manager
  for command in curl unzip openssl ss; do command -v "$command" >/dev/null 2>&1 || missing+=("$command"); done
  ((${#missing[@]} == 0)) && return
  command -v apt-get >/dev/null 2>&1 && pkg_manager=apt || \
    command -v dnf >/dev/null 2>&1 && pkg_manager=dnf || \
    command -v yum >/dev/null 2>&1 && pkg_manager=yum || \
    command -v apk >/dev/null 2>&1 && pkg_manager=apk || \
    command -v pacman >/dev/null 2>&1 && pkg_manager=pacman || \
    die "缺少命令：${missing[*]}；未识别包管理器，请手动安装后重试。"
  info "安装依赖：${missing[*]}"
  case "$pkg_manager" in
    apt) apt-get update; apt-get install -y --no-install-recommends curl unzip openssl iproute2 ;;
    dnf) dnf install -y curl unzip openssl iproute ;;
    yum) yum install -y curl unzip openssl iproute ;;
    apk) apk add --no-cache curl unzip openssl iproute2 ;;
    pacman) pacman -Sy --noconfirm curl unzip openssl iproute2 ;;
  esac
}

arch_name() { case "$(uname -m)" in x86_64) printf 'amd64' ;; aarch64) printf 'aarch64' ;; esac; }
official_url() { printf 'https://dl.nssurge.com/snell/snell-server-v%s-linux-%s.zip' "$(normalize_version "$1")" "$(arch_name)"; }

download_binary() {
  local version="$1" url temp candidate
  url=$(official_url "$version")
  temp=$(mktemp -d)
  trap 'rm -rf "$temp"' RETURN
  info "从官方地址下载 Snell v$(normalize_version "$version")…"
  curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --retry 2 --output "$temp/snell.zip" "$url" || die '官方下载失败；不会使用第三方备用源。'
  unzip -tq "$temp/snell.zip" >/dev/null || die '下载包校验失败。'
  unzip -q "$temp/snell.zip" -d "$temp/out"
  candidate=$(find "$temp/out" -maxdepth 2 -type f -name snell-server -print -quit)
  [[ -n "$candidate" && -f "$candidate" ]] || die '下载包内未找到 snell-server。'
  chmod 0755 "$candidate"
  "$candidate" --version >/dev/null 2>&1 || die 'Snell 二进制无法正常执行。'
  install -m 0755 "$candidate" "$BIN.new"
  trap - RETURN
  rm -rf "$temp"
}

prepare_dir() {
  id -u "$USER" >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin "$USER"
  install -d -o root -g "$USER" -m 0750 "$DIR"
}

write_config() {
  local version="$1" port="$2" psk="$3" mode="$4"
  cat > "$CONFIG" <<EOF
[snell-server]
listen = 0.0.0.0:$port
psk = $psk
version = $version
tfo = true
EOF
  [[ "$version" == 6 ]] && printf 'mode = %s\n' "$mode" >> "$CONFIG"
  chown root:"$USER" "$CONFIG"; chmod 0640 "$CONFIG"
}

write_service() {
  cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Personal Snell proxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
Group=$USER
ExecStart=$BIN -c $CONFIG
Restart=on-failure
RestartSec=5
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

write_metadata() {
  local version="$1" host="$2" port="$3" psk="$4" mode="$5"
  cat > "$META" <<EOF
VERSION=$version
HOST=$host
PORT=$port
PSK=$psk
MODE=$mode
EOF
  cat > "$CONNECTIONS" <<EOF
# 敏感文件：不要上传、截图或分享。
# 复制下面一行至 Surge 配置的 [Proxy] 段：
$(surge_line "$version" "$host" "$port" "$psk" "$mode")
EOF
  chown root:"$USER" "$META" "$CONNECTIONS"; chmod 0640 "$META" "$CONNECTIONS"
}

read_metadata() {
  [[ -f "$META" ]] || die '未找到 Snell 配置元数据。'
  # shellcheck disable=SC1090
  source "$META"
}

choose_version() {
  local supplied="${1:-}" choice
  if [[ -n "$supplied" ]]; then is_supported_version "$supplied" || die '仅可选择 4、5、6。'; printf '%s' "$supplied"; return; fi
  printf '选择 Snell 版本：4) v4.1.1  5) v5.0.1（默认，推荐）  6) v6.0.0rc2 Beta\n' >&2
  choice=$(ask '版本' 5)
  is_supported_version "$choice" || die '仅可选择 4、5、6。'
  printf '%s' "$choice"
}

install_node() {
  local version host port psk mode
  require_systemd_linux; install_dependencies; prepare_dir
  [[ ! -f "$CONFIG" ]] || die '已存在 Snell 配置；请使用 update/status/show，或先执行 uninstall。'
  version=$(choose_version "${1:-}")
  host=$(ask 'Surge 连接地址（域名或公网 IP）')
  valid_host "$host" || die '连接地址格式无效。'
  port=$(ask 'Snell TCP/UDP 端口' 6160)
  valid_port "$port" || die '端口无效。'
  port_free "$port" || die "端口 $port 已被占用。"
  mode=default
  if [[ "$version" == 6 ]]; then mode=$(ask 'Snell v6 模式（default/unshaped）' default); [[ "$mode" == default || "$mode" == unshaped ]] || die '仅允许 default 或 unshaped；unsafe-raw 不提供。'; fi
  psk=$(random_psk)
  download_binary "$version"
  mv -f "$BIN.new" "$BIN"
  write_config "$version" "$port" "$psk" "$mode"
  write_service
  systemctl enable --now "$UNIT"
  systemctl is-active --quiet "$UNIT" || die '服务未能启动；请执行 status 查看日志。'
  write_metadata "$version" "$host" "$port" "$psk" "$mode"
  info '完成。请在服务商安全组与 UFW 放行所选端口的 TCP 和 UDP。'
  show_node
}

status_node() {
  [[ -f "$CONFIG" ]] || die '未安装。'
  systemctl --no-pager --full status "$UNIT" || true
  ss -lntup | grep -E ":$(awk -F ' = ' '/^listen/ {sub(/^.*:/, "", $2); print $2}' "$CONFIG")[[:space:]]" || true
}

show_node() { [[ -f "$CONNECTIONS" ]] || die '未找到连接信息。'; cat "$CONNECTIONS"; }

update_node() {
  local version="${1:-}" previous
  [[ -f "$CONFIG" ]] || die '未安装。'
  read_metadata
  version=${version:-$VERSION}; is_supported_version "$version" || die '仅可选择 4、5、6。'
  require_systemd_linux; install_dependencies; download_binary "$version"
  cp -f "$BIN" "$PREVIOUS"
  mv -f "$BIN.new" "$BIN"
  write_config "$version" "$PORT" "$PSK" "$MODE"
  systemctl restart "$UNIT"
  if ! systemctl is-active --quiet "$UNIT"; then
    info '更新后的服务未启动，正在回滚旧二进制。'
    mv -f "$PREVIOUS" "$BIN"; systemctl restart "$UNIT" || true
    die '更新失败，已尝试回滚。'
  fi
  rm -f "$PREVIOUS"
  write_metadata "$version" "$HOST" "$PORT" "$PSK" "$MODE"
  info "已更新至 Snell v$(normalize_version "$version")。"
}

uninstall_node() {
  [[ -f "$CONFIG" || -f "/etc/systemd/system/$UNIT.service" ]] || die '未安装。'
  local answer
  read -r -p '确认删除本脚本创建的 Snell 服务、二进制和 /etc/snell-node？[y/N] ' answer
  [[ "$answer" =~ ^[yY]$ ]] || { info '已取消。'; return; }
  systemctl disable --now "$UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT.service" "$BIN" "$BIN.new"
  rm -rf "$DIR"
  systemctl daemon-reload
  userdel "$USER" 2>/dev/null || true
  info '已卸载。防火墙规则未改动。'
}

main() {
  case "${1:-}" in
    -h|--help|help|'') usage; return ;;
  esac
  root
  case "$1" in
    install) install_node "${2:-}" ;;
    status) status_node ;;
    show) show_node ;;
    update) update_node "${2:-}" ;;
    uninstall) uninstall_node ;;
    *) die "未知命令：$1" ;;
  esac
}

[[ "${SNELL_NODE_NO_MAIN:-0}" == 1 ]] || main "$@"
