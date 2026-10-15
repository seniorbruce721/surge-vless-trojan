#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/surge-node.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "expected output not to contain [$2], got [$1]"; }

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

write_os_release() {
  local file="$1" id="$2" version="$3" pretty="$4"
  cat > "$file" <<EOF
ID=$id
VERSION_ID="$version"
PRETTY_NAME="$pretty"
EOF
}

write_os_release "$TEST_TMP/debian-12" debian 12 'Debian GNU/Linux 12'
write_os_release "$TEST_TMP/debian-13" debian 13 'Debian GNU/Linux 13'
write_os_release "$TEST_TMP/ubuntu-2404" ubuntu 24.04 'Ubuntu 24.04 LTS'
write_os_release "$TEST_TMP/debian-11" debian 11 'Debian GNU/Linux 11'

for fixture in debian-12 debian-13 ubuntu-2404; do
  OS_RELEASE_FILE="$TEST_TMP/$fixture" SURGE_NODE_NO_MAIN=1 /bin/bash -c '
    source "$1"
    uname() { printf "x86_64\n"; }
    check_os
  ' bash "$SCRIPT"
done

if unsupported_output=$(OS_RELEASE_FILE="$TEST_TMP/debian-11" SURGE_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  uname() { printf "x86_64\n"; }
  check_os
' bash "$SCRIPT" 2>&1); then
  fail 'Debian 11 was accepted'
fi
assert_contains "$unsupported_output" 'Debian 12 / 13'

dispatch_output=$(SURGE_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  root() { :; }
  install_node() { printf "dual-install\n"; }
  install_trojan_node() { printf "trojan-only-install\n"; }
  main install trojan
  main install
' bash "$SCRIPT")
assert_eq "$dispatch_output" $'trojan-only-install\ndual-install'

TEST_SCRIPT="$TEST_TMP/surge-node-testable.sh"
TEST_ROOT="$TEST_TMP/root"
mkdir -p "$TEST_ROOT/etc/systemd/system" "$TEST_ROOT/etc/letsencrypt/renewal-hooks/deploy" "$TEST_ROOT/usr/local/bin"
sed \
  -e "s|readonly DIR='/etc/surge-node'|readonly DIR='$TEST_ROOT/etc/surge-node'|" \
  -e "s|readonly BIN='/usr/local/bin/xray'|readonly BIN='$TEST_ROOT/usr/local/bin/xray'|" \
  -e "s|/etc/systemd/system|$TEST_ROOT/etc/systemd/system|g" \
  -e "s|/etc/letsencrypt/renewal-hooks/deploy|$TEST_ROOT/etc/letsencrypt/renewal-hooks/deploy|g" \
  "$SCRIPT" > "$TEST_SCRIPT"

mkdir -p "$TEST_ROOT/etc/surge-node/tls"
config_output=$(SURGE_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  chown() { :; }
  write_trojan_config 24443 preserve-password
  curl() { printf "198.51.100.23"; }
  write_trojan_connections 24443 trojan.example.com preserve-password
  show_node
' bash "$TEST_SCRIPT")

python3 - "$TEST_ROOT/etc/surge-node/config.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

assert len(config["inbounds"]) == 1
inbound = config["inbounds"][0]
assert inbound["tag"] == "trojan-tls"
assert inbound["protocol"] == "trojan"
assert inbound["port"] == 24443
assert inbound["settings"]["clients"][0]["password"] == "preserve-password"
assert config["outbounds"][0]["protocol"] == "freedom"
PY
assert_contains "$config_output" 'Personal-Trojan = trojan, trojan.example.com, 24443, password=preserve-password, sni=trojan.example.com'
assert_not_contains "$(cat "$TEST_ROOT/etc/surge-node/config.json")" 'vless'

INSTALL_ROOT="$TEST_TMP/install-root"
mkdir -p "$INSTALL_ROOT/etc/systemd/system" "$INSTALL_ROOT/etc/letsencrypt/renewal-hooks/deploy" \
  "$INSTALL_ROOT/usr/local/bin" "$INSTALL_ROOT/etc/snell-node"
printf 'snell-install-sentinel\n' > "$INSTALL_ROOT/etc/snell-node/sentinel"
sed \
  -e "s|readonly DIR='/etc/surge-node'|readonly DIR='$INSTALL_ROOT/etc/surge-node'|" \
  -e "s|readonly BIN='/usr/local/bin/xray'|readonly BIN='$INSTALL_ROOT/usr/local/bin/xray'|" \
  -e "s|/etc/systemd/system|$INSTALL_ROOT/etc/systemd/system|g" \
  -e "s|/etc/letsencrypt/renewal-hooks/deploy|$INSTALL_ROOT/etc/letsencrypt/renewal-hooks/deploy|g" \
  "$SCRIPT" > "$TEST_TMP/surge-node-install.sh"

install_output=$(CALL_LOG="$TEST_TMP/install-calls" SURGE_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  check_os() { :; }
  deps() { :; }
  install_xray() {
    cat > "$BIN" <<"XRAY"
#!/usr/bin/env bash
exit 0
XRAY
    chmod +x "$BIN"
  }
  prepare_dir() { install -d -m 0750 "$DIR" "$TLS"; }
  ask() {
    case "$1" in
      *"Trojan 域名"*) printf "trojan.example.com" ;;
      *"证书通知邮箱"*) printf "owner@example.com" ;;
      *"Trojan TCP 端口"*) printf "24443" ;;
      *) return 1 ;;
    esac
  }
  port_free() { return 0; }
  issue_cert() { :; }
  password() { printf "install-password"; }
  chown() { :; }
  write_unit() { printf "write-unit:%s\n" "$1" >> "$CALL_LOG"; }
  systemctl() { local IFS=" "; printf "systemctl:%s\n" "$*" >> "$CALL_LOG"; }
  curl() { printf "198.51.100.23"; }
  install_trojan_node
' bash "$TEST_TMP/surge-node-install.sh")
assert_contains "$install_output" 'Personal-Trojan = trojan, trojan.example.com, 24443, password=install-password, sni=trojan.example.com'
assert_not_contains "$(cat "$INSTALL_ROOT/etc/surge-node/config.json")" 'vless'
assert_eq "$(cat "$INSTALL_ROOT/etc/snell-node/sentinel")" 'snell-install-sentinel'
assert_contains "$(cat "$TEST_TMP/install-calls")" 'write-unit:Personal Trojan TLS node'
assert_contains "$(cat "$TEST_TMP/install-calls")" 'systemctl:enable --now surge-node'

FAKE_BIN="$TEST_TMP/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl:%s\n' "$*"
EOF
cat > "$FAKE_BIN/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 4096 [::]:24443 [::]:* users:(("xray",pid=123,fd=7))\n'
EOF
chmod +x "$FAKE_BIN/systemctl" "$FAKE_BIN/ss"
cat > "$TEST_ROOT/usr/local/bin/xray" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *'run -test -config'* ]]
EOF
chmod +x "$TEST_ROOT/usr/local/bin/xray"

status_output=$(PATH="$FAKE_BIN:/usr/bin:/bin" SURGE_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  status_node
' bash "$TEST_SCRIPT")
assert_contains "$status_output" '[::]:24443'

assert_collision_refused() {
  local target="$1" expected="$2" output
  rm -rf "$TEST_ROOT/etc/surge-node"
  rm -f "$TEST_ROOT/etc/systemd/system/surge-node.service" "$TEST_ROOT/usr/local/bin/xray"
  case "$target" in
    config) mkdir -p "$TEST_ROOT/etc/surge-node"; printf 'keep-config\n' > "$TEST_ROOT/etc/surge-node/sentinel" ;;
    unit) printf 'keep-unit\n' > "$TEST_ROOT/etc/systemd/system/surge-node.service" ;;
    binary) printf 'keep-binary\n' > "$TEST_ROOT/usr/local/bin/xray" ;;
  esac
  if output=$(COLLISION_MARKER="$TEST_TMP/collision-deps-called" SURGE_NODE_NO_MAIN=1 /bin/bash -c '
    source "$1"
    check_os() { :; }
    deps() { printf "called\n" > "$COLLISION_MARKER"; }
    install_trojan_node
  ' bash "$TEST_SCRIPT" 2>&1); then
    fail "$target collision was accepted"
  fi
  [[ ! -e "$TEST_TMP/collision-deps-called" ]] || fail "$target collision was detected after dependency installation began"
  assert_contains "$output" "$expected"
  case "$target" in
    config) assert_eq "$(cat "$TEST_ROOT/etc/surge-node/sentinel")" 'keep-config' ;;
    unit) assert_eq "$(cat "$TEST_ROOT/etc/systemd/system/surge-node.service")" 'keep-unit' ;;
    binary) assert_eq "$(cat "$TEST_ROOT/usr/local/bin/xray")" 'keep-binary' ;;
  esac
}

assert_collision_refused config '配置目录已存在'
assert_collision_refused unit 'systemd 服务已存在'
assert_collision_refused binary 'Xray 路径已存在'

LIFECYCLE_ROOT="$TEST_TMP/lifecycle"
mkdir -p "$LIFECYCLE_ROOT/etc/surge-node/tls" "$LIFECYCLE_ROOT/etc/systemd/system" \
  "$LIFECYCLE_ROOT/etc/letsencrypt/renewal-hooks/deploy" "$LIFECYCLE_ROOT/usr/local/bin" "$LIFECYCLE_ROOT/etc/snell-node"
printf 'snell-must-survive\n' > "$LIFECYCLE_ROOT/etc/snell-node/sentinel"
sed \
  -e "s|readonly DIR='/etc/surge-node'|readonly DIR='$LIFECYCLE_ROOT/etc/surge-node'|" \
  -e "s|readonly BIN='/usr/local/bin/xray'|readonly BIN='$LIFECYCLE_ROOT/usr/local/bin/xray'|" \
  -e "s|/etc/systemd/system|$LIFECYCLE_ROOT/etc/systemd/system|g" \
  -e "s|/etc/letsencrypt/renewal-hooks/deploy|$LIFECYCLE_ROOT/etc/letsencrypt/renewal-hooks/deploy|g" \
  "$SCRIPT" > "$TEST_TMP/surge-node-lifecycle.sh"
printf '{}\n' > "$LIFECYCLE_ROOT/etc/surge-node/config.json"
printf 'saved-connection\n' > "$LIFECYCLE_ROOT/etc/surge-node/connections.txt"
printf 'old-xray\n' > "$LIFECYCLE_ROOT/usr/local/bin/xray"
printf 'unit\n' > "$LIFECYCLE_ROOT/etc/systemd/system/surge-node.service"

PATH="$FAKE_BIN:/usr/bin:/bin" SURGE_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  install_xray() {
    cat > "$BIN" <<"XRAY"
#!/usr/bin/env bash
exit 0
XRAY
    chmod +x "$BIN"
  }
  update_node
' bash "$TEST_TMP/surge-node-lifecycle.sh" >/dev/null
assert_contains "$(cat "$LIFECYCLE_ROOT/usr/local/bin/xray")" '#!/usr/bin/env bash'

printf 'y\n' | PATH="$FAKE_BIN:/usr/bin:/bin" SURGE_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  userdel() { :; }
  uninstall_node
' bash "$TEST_TMP/surge-node-lifecycle.sh" >/dev/null
[[ ! -e "$LIFECYCLE_ROOT/etc/surge-node" ]] || fail 'uninstall left the surge-node config directory'
[[ ! -e "$LIFECYCLE_ROOT/etc/systemd/system/surge-node.service" ]] || fail 'uninstall left the surge-node unit'
assert_eq "$(cat "$LIFECYCLE_ROOT/etc/snell-node/sentinel")" 'snell-must-survive'

printf 'PASS: Debian 13, Trojan-only install behavior, dynamic status, collision refusal, and isolated lifecycle\n'
