#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/snell-node.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "expected output not to contain [$2], got [$1]"; }

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

write_os_release() {
  local name="$1" id="$2" id_like="$3"
  cat > "$TEST_TMP/$name" <<EOF
ID=$id
ID_LIKE="$id_like"
EOF
}

detect_with() {
  local fixture="$1" path="$2"
  env "PATH=$path" "OS_RELEASE_FILE=$fixture" SNELL_NODE_NO_MAIN=1 /bin/bash -c '
    source "$1"
    detect_package_manager
  ' bash "$SCRIPT"
}

write_os_release debian debian debian
write_os_release ubuntu ubuntu debian
write_os_release fedora fedora rhel
write_os_release rocky rocky rhel
write_os_release alpine alpine ''
write_os_release arch arch ''
write_os_release unknown gentoo ''

FAKE_BIN="$TEST_TMP/fake-bin"
mkdir -p "$FAKE_BIN"
for command in dnf yum; do
  cat > "$FAKE_BIN/$command" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$FAKE_BIN/$command"
done

assert_eq "$(detect_with "$TEST_TMP/debian" "$FAKE_BIN:/usr/bin:/bin")" apt
assert_eq "$(detect_with "$TEST_TMP/ubuntu" "$FAKE_BIN:/usr/bin:/bin")" apt
assert_eq "$(detect_with "$TEST_TMP/fedora" "$FAKE_BIN:/usr/bin:/bin")" dnf
assert_eq "$(detect_with "$TEST_TMP/rocky" "$FAKE_BIN:/usr/bin:/bin")" dnf
rm "$FAKE_BIN/dnf"
assert_eq "$(detect_with "$TEST_TMP/rocky" "$FAKE_BIN:/usr/bin:/bin")" yum
assert_eq "$(detect_with "$TEST_TMP/alpine" "$FAKE_BIN:/usr/bin:/bin")" apk
assert_eq "$(detect_with "$TEST_TMP/arch" "$FAKE_BIN:/usr/bin:/bin")" pacman

if unknown_output=$(detect_with "$TEST_TMP/unknown" "$FAKE_BIN:/usr/bin:/bin" 2>&1); then
  fail 'unknown Linux distribution was accepted'
fi
assert_contains "$unknown_output" '未识别的 Linux 发行版'

APT_BIN="$TEST_TMP/apt-bin"
APT_LOG="$TEST_TMP/apt.log"
mkdir -p "$APT_BIN"
cat > "$APT_BIN/apt-get" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$APT_LOG"
EOF
chmod +x "$APT_BIN/apt-get"
env "PATH=$APT_BIN" "OS_RELEASE_FILE=$TEST_TMP/debian" "APT_LOG=$APT_LOG" \
  SNELL_NODE_NO_MAIN=1 /bin/bash -c '
    source "$1"
    install_dependencies
  ' bash "$SCRIPT" >/dev/null
assert_eq "$(sed -n '1p' "$APT_LOG")" update
assert_eq "$(sed -n '2p' "$APT_LOG")" \
  'install -y --no-install-recommends curl unzip openssl iproute2'

assert_dependency_install() {
  local fixture="$1" executable="$2" expected="$3" bin log
  bin="$TEST_TMP/install-$executable-bin"
  log="$TEST_TMP/install-$executable.log"
  mkdir -p "$bin"
  cat > "$bin/$executable" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PM_LOG"
EOF
  chmod +x "$bin/$executable"
  env "PATH=$bin" "OS_RELEASE_FILE=$fixture" "PM_LOG=$log" SNELL_NODE_NO_MAIN=1 \
    /bin/bash -c '
      source "$1"
      install_dependencies
    ' bash "$SCRIPT" >/dev/null
  assert_eq "$(cat "$log")" "$expected"
}

assert_dependency_install "$TEST_TMP/fedora" dnf 'install -y curl unzip openssl iproute'
assert_dependency_install "$TEST_TMP/rocky" yum 'install -y curl unzip openssl iproute'
assert_dependency_install "$TEST_TMP/alpine" apk 'add --no-cache curl unzip openssl iproute2'
assert_dependency_install "$TEST_TMP/arch" pacman '-Sy --noconfirm curl unzip openssl iproute2'

START_BIN="$TEST_TMP/start-bin"
START_COUNT="$TEST_TMP/start-count"
mkdir -p "$START_BIN"
printf '0\n' > "$START_COUNT"
cat > "$START_BIN/systemctl" <<'EOF'
#!/bin/bash
[[ "$1" == is-active ]] && exit 0
exit 0
EOF
cat > "$START_BIN/ss" <<'EOF'
#!/bin/bash
count=$(cat "$START_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$START_COUNT"
((count >= 3)) && printf 'LISTEN 0 4096 0.0.0.0:6160 0.0.0.0:*\n'
EOF
chmod +x "$START_BIN/systemctl" "$START_BIN/ss"
if env "PATH=$START_BIN:/usr/bin:/bin" "START_COUNT=$START_COUNT" SNELL_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    wait_for_runtime 5 6160 "0.0.0.0:6160" 2 0
  ' bash "$SCRIPT"; then
  fail 'startup validation succeeded before the TCP listener appeared'
fi
assert_eq "$(cat "$START_COUNT")" 2
printf '0\n' > "$START_COUNT"
env "PATH=$START_BIN:/usr/bin:/bin" "START_COUNT=$START_COUNT" SNELL_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    wait_for_runtime 5 6160 "0.0.0.0:6160" 5 0
  ' bash "$SCRIPT"
assert_eq "$(cat "$START_COUNT")" 3

RECOVERY_ROOT="$TEST_TMP/recovery-root"
RECOVERY_SCRIPT="$TEST_TMP/snell-node-recovery.sh"
mkdir -p "$RECOVERY_ROOT/etc/snell-node" "$RECOVERY_ROOT/usr/local/bin"
sed \
  -e "s|readonly DIR='/etc/snell-node'|readonly DIR='$RECOVERY_ROOT/etc/snell-node'|" \
  -e "s|readonly BIN='/usr/local/bin/snell-server'|readonly BIN='$RECOVERY_ROOT/usr/local/bin/snell-server'|" \
  "$SCRIPT" > "$RECOVERY_SCRIPT"
cat > "$RECOVERY_ROOT/etc/snell-node/config.conf" <<'EOF'
[snell-server]
listen = 0.0.0.0:6160
psk = preserve-this-psk
version = 6
tfo = true
mode = default
EOF
original_config=$(cat "$RECOVERY_ROOT/etc/snell-node/config.conf")
show_output=$(SNELL_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  interactive_terminal() { return 0; }
  ask() { printf "203.0.113.7"; }
  chown() { :; }
  show_node
' bash "$RECOVERY_SCRIPT")
assert_eq "$(cat "$RECOVERY_ROOT/etc/snell-node/config.conf")" "$original_config"
assert_contains "$(cat "$RECOVERY_ROOT/etc/snell-node/meta.env")" 'HOST=203.0.113.7'
assert_contains "$(cat "$RECOVERY_ROOT/etc/snell-node/meta.env")" 'PORT=6160'
assert_contains "$(cat "$RECOVERY_ROOT/etc/snell-node/meta.env")" 'PSK=preserve-this-psk'
assert_contains "$(cat "$RECOVERY_ROOT/etc/snell-node/connections.txt")" 'version=6, mode=default'
assert_contains "$show_output" 'Snell server version: v6.0.0rc2'
assert_contains "$show_output" '203.0.113.7, 6160'
assert_contains "$show_output" 'psk=preserve-this-psk'

set +e
noninteractive_output=$(SNELL_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  interactive_terminal() { return 1; }
  show_node
' bash "$RECOVERY_SCRIPT" 2>&1)
noninteractive_rc=$?
set -e
[[ "$noninteractive_rc" -ne 0 ]] || fail 'non-interactive show unexpectedly succeeded'
assert_contains "$noninteractive_output" '交互式终端'
assert_not_contains "$noninteractive_output" 'preserve-this-psk'

AUTO_ROOT="$TEST_TMP/auto-root"
AUTO_SCRIPT="$TEST_TMP/snell-node-auto.sh"
mkdir -p "$AUTO_ROOT/etc/systemd/system" "$AUTO_ROOT/usr/local/bin"
sed \
  -e "s|readonly DIR='/etc/snell-node'|readonly DIR='$AUTO_ROOT/etc/snell-node'|" \
  -e "s|readonly BIN='/usr/local/bin/snell-server'|readonly BIN='$AUTO_ROOT/usr/local/bin/snell-server'|" \
  -e "s|/etc/systemd/system|$AUTO_ROOT/etc/systemd/system|g" \
  "$SCRIPT" > "$AUTO_SCRIPT"
printf '0\n' > "$START_COUNT"
install_output=$(env "PATH=$START_BIN:/usr/bin:/bin" "START_COUNT=$START_COUNT" SNELL_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    require_systemd_linux() { :; }
    install_dependencies() { :; }
    prepare_dir() { install -d -m 0750 "$DIR"; }
    download_binary() { printf "snell-v6-binary\n" > "$BIN.new"; chmod 0755 "$BIN.new"; }
    ask() {
      case "$1" in
        *"连接地址"*) printf "198.51.100.7" ;;
        *"端口"*) printf "6160" ;;
        *"模式"*) printf "default" ;;
        *) return 1 ;;
      esac
    }
    port_free() { return 0; }
    random_psk() { printf "auto-display-psk"; }
    collect_network_state() {
      IPV4_DETECTED=yes
      IPV6_DETECTED=no
      IPV6_CONNECTIVITY=no
      PUBLIC_IPV6=
    }
    interactive_terminal() { return 0; }
    chown() { :; }
    install_node 6
  ' bash "$AUTO_SCRIPT")
assert_contains "$install_output" 'Snell server version: v6.0.0rc2'
assert_contains "$install_output" '198.51.100.7, 6160'
assert_contains "$install_output" 'psk=auto-display-psk'

printf 'PASS: dependency detection, startup wait, metadata recovery, interactive install output, and PSK output gating\n'
