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
  repair-dualstack   原地修复 Snell v6 的 IPv4/IPv6 监听；v4/v5 不改配置
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

listen_value() {
  local version="$1" port="$2" ipv6_detected="$3" ipv6_connected="$4"
  if [[ "$version" == 6 && "$ipv6_detected" == yes && "$ipv6_connected" == yes ]]; then
    printf '0.0.0.0:%s,[::]:%s' "$port" "$port"
  else
    printf '0.0.0.0:%s' "$port"
  fi
}

public_ipv6_addresses() {
  local line address first found=no
  while IFS= read -r line; do
    case "$line" in
      *tentative*|*dadfailed*|*deprecated*) continue ;;
    esac
    address=$(printf '%s\n' "$line" | awk '{print $4}')
    address=${address%/*}
    case "$address" in
      ''|::1|fe8*|fe9*|fea*|feb*|fc*|fd*|2001:db8:*) continue ;;
    esac
    first=${address%%:*}
    if [[ "$first" =~ ^[23][0-9A-Fa-f]{0,3}$ ]]; then
      printf '%s\n' "$address"
      found=yes
    fi
  done < <(ip -6 -o addr show scope global 2>/dev/null)
  [[ "$found" == yes ]]
}

public_ipv6_address() {
  local addresses
  addresses=$(public_ipv6_addresses) || return 1
  printf '%s\n' "$addresses" | sed -n '1p'
}

ipv6_connectivity() {
  local address="$1" trace
  trace=$(curl -6 --fail --silent --show-error --noproxy '*' --interface "$address" \
    --connect-timeout 5 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || return 1
  printf '%s\n' "$trace" | grep -Eq '^ip=[0-9A-Fa-f:]+$'
}

ipv4_detected() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | grep -Eq '^[0-9]+\.'
}

collect_network_state() {
  local addresses address
  IPV4_DETECTED=no
  IPV6_DETECTED=no
  IPV6_CONNECTIVITY=no
  PUBLIC_IPV6=''
  ipv4_detected && IPV4_DETECTED=yes
  if addresses=$(public_ipv6_addresses); then
    IPV6_DETECTED=yes
    PUBLIC_IPV6=$(printf '%s\n' "$addresses" | sed -n '1p')
    while IFS= read -r address; do
      if ipv6_connectivity "$address"; then
        PUBLIC_IPV6="$address"
        IPV6_CONNECTIVITY=yes
        break
      fi
    done <<< "$addresses"
  fi
  return 0
}

listener_present() {
  local family="$1" protocol="$2" port="$3" flags output
  case "$protocol/$family" in
    tcp/4) flags='-lnt4' ;;
    udp/4) flags='-lnu4' ;;
    tcp/6) flags='-lnt6' ;;
    udp/6) flags='-lnu6' ;;
    *) return 1 ;;
  esac
  output=$(ss -H "$flags" "sport = :$port" 2>/dev/null) || true
  [[ -n "$output" ]]
}

service_active() { systemctl is-active --quiet "$UNIT"; }

validate_runtime() {
  local version="$1" port="$2" listen="$3"
  service_active || return 1
  listener_present 4 tcp "$port" || return 1
  if [[ "$version" == 6 && "$listen" == *'[::]'* ]]; then
    listener_present 6 tcp "$port" || return 1
  fi
}

check_word() { if "$@"; then printf 'yes'; else printf 'no'; fi; }

status_report() {
  local version="$1" port="$2" listen="$3" listen_mode service_status
  collect_network_state
  [[ "$listen" == *'[::]'* ]] && listen_mode='Dual-stack' || listen_mode='IPv4-only'
  service_active && service_status=active || service_status=inactive
  printf 'Snell version: v%s\n' "$version"
  printf 'IPv4 detected: %s\n' "$IPV4_DETECTED"
  printf 'IPv6 detected: %s\n' "$IPV6_DETECTED"
  printf 'IPv6 connectivity: %s\n' "$IPV6_CONNECTIVITY"
  printf 'Listen mode: %s\n' "$listen_mode"
  printf 'TCP IPv4 listening: %s\n' "$(check_word listener_present 4 tcp "$port")"
  printf 'TCP IPv6 listening: %s\n' "$(check_word listener_present 6 tcp "$port")"
  printf 'UDP IPv4 listening: %s\n' "$(check_word listener_present 4 udp "$port")"
  printf 'UDP IPv6 listening: %s\n' "$(check_word listener_present 6 udp "$port")"
  printf 'Service status: %s\n' "$service_status"
}

backup_config() {
  local config="$1" backup
  backup="${config}.bak-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  cp -p "$config" "$backup" || return 1
  printf '%s' "$backup"
}

config_value() {
  local config="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      print
      exit
    }
  ' "$config"
}

listen_port() {
  local listen="$1" first
  first=${listen%%,*}
  printf '%s' "${first##*:}"
}

validate_configured_runtime() {
  local config="$1" version="$2" port="$3" listen="$4"
  local actual_version actual_listen actual_port
  actual_version=$(config_value "$config" version)
  actual_listen=$(config_value "$config" listen)
  actual_port=$(listen_port "$actual_listen")
  [[ "$actual_version" == "$version" ]] || return 1
  [[ "$actual_listen" == "$listen" ]] || return 1
  [[ "$actual_port" == "$port" ]] || return 1
  validate_runtime "$version" "$port" "$listen"
}

rewrite_config_file() {
  local config="$1" version="$2" listen="$3" mode="$4" owner_group="${5:-}" temp
  temp=$(mktemp "${config}.tmp.XXXXXX") || return 1
  trap 'rm -f "$temp"' RETURN
  if ! awk -v listen="$listen" -v version="$version" -v mode="$mode" '
    BEGIN { have_listen=0; have_version=0; have_mode=0 }
    /^[[:space:]]*listen[[:space:]]*=/ {
      print "listen = " listen; have_listen=1; next
    }
    /^[[:space:]]*version[[:space:]]*=/ {
      print "version = " version; have_version=1; next
    }
    /^[[:space:]]*mode[[:space:]]*=/ {
      have_mode=1
      if (version == "6") print "mode = " mode
      next
    }
    /^[[:space:]]*ipv6[[:space:]]*=/ {
      if (version == "6") next
    }
    { print }
    END {
      if (!have_listen) print "listen = " listen
      if (!have_version) print "version = " version
      if (version == "6" && !have_mode) print "mode = " mode
    }
  ' "$config" > "$temp"; then
    trap - RETURN
    rm -f "$temp"
    return 1
  fi
  if [[ -n "$owner_group" ]]; then
    if ! install -o root -g "$owner_group" -m 0640 "$temp" "$config"; then
      trap - RETURN
      rm -f "$temp"
      return 1
    fi
  else
    if ! install -m 0600 "$temp" "$config"; then
      trap - RETURN
      rm -f "$temp"
      return 1
    fi
  fi
  trap - RETURN
  rm -f "$temp"
}

activate_runtime_change() {
  local config="$1" config_backup="$2" version="$3" port="$4" listen="$5" mode="$6"
  local binary_path="${7:-}" binary_backup="${8:-}" owner_group="${9:-}"
  local rollback_version rollback_listen rollback_port
  if rewrite_config_file "$config" "$version" "$listen" "$mode" "$owner_group" && \
    systemctl restart "$UNIT" && validate_configured_runtime "$config" "$version" "$port" "$listen"; then
    return 0
  fi

  info '新配置未通过验证，正在恢复旧配置和旧服务。'
  journalctl -u "$UNIT" -n 50 --no-pager || true
  if ! cp -p "$config_backup" "$config"; then
    info '无法恢复旧配置，请立即检查备份文件。'
    return 2
  fi
  if [[ -n "$binary_path" ]]; then
    if [[ -z "$binary_backup" || ! -f "$binary_backup" ]]; then
      info '旧二进制备份不存在，无法完成回滚。'
      return 2
    fi
    if ! mv -f "$binary_backup" "$binary_path"; then
      info '无法恢复旧二进制，请立即检查备份文件。'
      return 2
    fi
  fi
  rollback_version=$(config_value "$config" version)
  rollback_listen=$(config_value "$config" listen)
  rollback_port=$(listen_port "$rollback_listen")
  if is_supported_version "$rollback_version" && valid_port "$rollback_port" && \
    systemctl restart "$UNIT" && \
    validate_configured_runtime "$config" "$rollback_version" "$rollback_port" "$rollback_listen"; then
    info '旧配置和旧服务已恢复并通过验证。'
    return 1
  fi

  info '自动回滚后旧服务仍未通过验证，请立即检查日志和备份。'
  journalctl -u "$UNIT" -n 50 --no-pager || true
  return 2
}

require_systemd_linux() {
  [[ "$(uname -s)" == Linux ]] || die '仅支持 Linux。'
  command -v systemctl >/dev/null 2>&1 || die '需要 systemd；当前系统不支持 systemctl。'
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "不支持的 CPU 架构：$(uname -m)；仅支持 x86_64/aarch64。" ;; esac
}

install_dependencies() {
  local missing=() command pkg_manager
  for command in curl unzip openssl ss ip; do command -v "$command" >/dev/null 2>&1 || missing+=("$command"); done
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

render_config() {
  local version="$1" port="$2" psk="$3" mode="$4" listen="$5"
  cat <<EOF
[snell-server]
listen = $listen
psk = $psk
version = $version
tfo = true
EOF
  if [[ "$version" == 6 ]]; then
    printf 'mode = %s\n' "$mode"
  fi
}

write_config_file() {
  local config="$1" owner_group="$2" version="$3" port="$4" psk="$5" mode="$6" listen="$7"
  render_config "$version" "$port" "$psk" "$mode" "$listen" > "$config"
  if [[ -n "$owner_group" ]]; then
    chown root:"$owner_group" "$config"
    chmod 0640 "$config"
  else
    chmod 0600 "$config"
  fi
}

write_config() {
  local version="$1" port="$2" psk="$3" mode="$4" listen="${5:-0.0.0.0:$2}"
  write_config_file "$CONFIG" "$USER" "$version" "$port" "$psk" "$mode" "$listen"
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
  local version host port psk mode listen
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
  collect_network_state
  listen=$(listen_value "$version" "$port" "$IPV6_DETECTED" "$IPV6_CONNECTIVITY")
  download_binary "$version"
  mv -f "$BIN.new" "$BIN"
  write_config "$version" "$port" "$psk" "$mode" "$listen"
  write_service
  systemctl enable --now "$UNIT"
  if ! validate_configured_runtime "$CONFIG" "$version" "$port" "$listen"; then
    journalctl -u "$UNIT" -n 50 --no-pager || true
    die '服务或预期监听未能启动；已输出最近 50 行日志。'
  fi
  write_metadata "$version" "$host" "$port" "$psk" "$mode"
  info '完成。请在服务商安全组与 UFW 放行所选端口的 TCP 和 UDP。'
  status_report "$version" "$port" "$listen"
  show_node
}

status_node() {
  local config="${1:-$CONFIG}" version listen port
  [[ -f "$config" ]] || die '未安装。'
  version=$(config_value "$config" version)
  listen=$(config_value "$config" listen)
  port=$(listen_port "$listen")
  status_report "$version" "$port" "$listen"
  if ! validate_runtime "$version" "$port" "$listen"; then
    journalctl -u "$UNIT" -n 50 --no-pager || true
    return 1
  fi
}

show_node() {
  local version host listen port psk mode
  [[ -f "$CONFIG" && -f "$META" ]] || die '未找到连接信息。'
  version=$(config_value "$CONFIG" version)
  listen=$(config_value "$CONFIG" listen)
  port=$(listen_port "$listen")
  psk=$(config_value "$CONFIG" psk)
  mode=$(config_value "$CONFIG" mode)
  mode=${mode:-default}
  host=$(config_value "$META" HOST)
  is_supported_version "$version" || die '无法从当前配置读取有效版本。'
  valid_port "$port" || die '无法从当前配置读取有效端口。'
  [[ -n "$psk" && -n "$host" ]] || die '当前配置缺少 PSK 或 Surge 连接地址。'
  printf '# 敏感文件：不要上传、截图或分享。\n'
  printf '# 复制下面一行至 Surge 配置的 [Proxy] 段：\n'
  surge_line "$version" "$host" "$port" "$psk" "$mode"
  printf '\n'
}

update_node() {
  local version="${1:-}" mode listen config_backup current_version current_listen current_port current_psk
  [[ -f "$CONFIG" ]] || die '未安装。'
  read_metadata
  current_version=$(config_value "$CONFIG" version)
  current_listen=$(config_value "$CONFIG" listen)
  current_port=$(listen_port "$current_listen")
  current_psk=$(config_value "$CONFIG" psk)
  valid_port "$current_port" || die '无法从当前配置读取有效端口。'
  [[ -n "$current_psk" ]] || die '无法从当前配置读取 PSK。'
  version=${version:-$current_version}; is_supported_version "$version" || die '仅可选择 4、5、6。'
  mode=$(config_value "$CONFIG" mode)
  mode=${mode:-${MODE:-default}}
  [[ "$version" == 6 ]] || mode=default
  require_systemd_linux; install_dependencies; download_binary "$version"
  collect_network_state
  listen=$(listen_value "$version" "$current_port" "$IPV6_DETECTED" "$IPV6_CONNECTIVITY")
  config_backup=$(backup_config "$CONFIG") || die '创建配置备份失败；未修改当前服务。'
  cp -p "$BIN" "$PREVIOUS" || die '创建二进制备份失败；未修改当前服务。'
  mv -f "$BIN.new" "$BIN" || die '无法安装新二进制；当前配置未修改。'
  if activate_runtime_change "$CONFIG" "$config_backup" "$version" "$current_port" "$listen" "$mode" "$BIN" "$PREVIOUS" "$USER"; then
    :
  else
    local change_status=$?
    (( change_status == 2 )) && die "更新失败，已恢复旧配置和旧二进制，但旧服务验证仍失败：$config_backup"
    die "更新失败，已恢复旧配置、旧二进制和旧服务：$config_backup"
  fi
  rm -f "$PREVIOUS"
  write_metadata "$version" "$HOST" "$current_port" "$current_psk" "$mode"
  info "已更新至 Snell v$(normalize_version "$version")；原配置备份：$config_backup"
  status_report "$version" "$current_port" "$listen"
}

repair_dualstack_node() {
  local config="${1:-$CONFIG}" owner_group="$USER" version listen port mode desired backup
  (($# < 2)) || owner_group="$2"
  [[ -f "$config" ]] || die '未安装。'
  version=$(config_value "$config" version)
  listen=$(config_value "$config" listen)
  port=$(listen_port "$listen")
  valid_port "$port" || die '无法从当前配置读取有效端口。'

  if [[ "$version" != 6 ]]; then
    info "Snell v$version 不支持官方多地址 listen；未修改配置。如需双栈，请明确执行 update 6 并同步修改 Surge 节点版本。"
    status_node "$config"
    return
  fi

  mode=$(config_value "$config" mode)
  mode=${mode:-default}
  collect_network_state
  desired=$(listen_value "$version" "$port" "$IPV6_DETECTED" "$IPV6_CONNECTIVITY")
  if [[ "$listen" == "$desired" ]] && ! grep -Eq '^[[:space:]]*ipv6[[:space:]]*=' "$config"; then
    info '当前 Snell v6 监听配置已符合检测结果，无需修改。'
    status_node "$config"
    return
  fi

  backup=$(backup_config "$config") || die '创建配置备份失败；未修改当前服务。'
  if activate_runtime_change "$config" "$backup" "$version" "$port" "$desired" "$mode" '' '' "$owner_group"; then
    :
  else
    local change_status=$?
    (( change_status == 2 )) && die "双栈修复失败，已恢复旧配置，但旧服务验证仍失败：$backup"
    die "双栈修复失败，已恢复旧配置和旧服务：$backup"
  fi
  info "已完成原地双栈修复；原配置备份：$backup"
  status_report "$version" "$port" "$desired"
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
    repair-dualstack) repair_dualstack_node ;;
    uninstall) uninstall_node ;;
    *) die "未知命令：$1" ;;
  esac
}

[[ "${SNELL_NODE_NO_MAIN:-0}" == 1 ]] || main "$@"
