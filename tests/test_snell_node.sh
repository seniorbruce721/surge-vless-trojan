#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/snell-node.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"; }
assert_true() { "$@" || fail "expected success: $*"; }
assert_false() { if "$@"; then fail "expected failure: $*"; fi; }

[[ -f "$SCRIPT" ]] || fail 'snell-node.sh does not exist yet'

export SNELL_NODE_NO_MAIN=1
# shellcheck source=/dev/null
source "$SCRIPT"

assert_true is_supported_version 4
assert_true is_supported_version 5
assert_true is_supported_version 6
assert_false is_supported_version 1
assert_false is_supported_version 3
assert_eq "$(normalize_version 4)" '4.1.1'
assert_eq "$(normalize_version 5)" '5.0.1'
assert_eq "$(normalize_version 6)" '6.0.0rc2'
assert_eq "$(surge_line 5 snell.example.com 6160 example-psk default)" \
  'Personal-Snell = snell, snell.example.com, 6160, psk=example-psk, version=5, reuse=true'
assert_eq "$(surge_line 6 snell.example.com 6160 example-psk default)" \
  'Personal-Snell = snell, snell.example.com, 6160, psk=example-psk, version=6, mode=default, reuse=true'

assert_eq "$(listen_value 4 6160 yes yes)" '0.0.0.0:6160'
assert_eq "$(listen_value 5 6160 yes yes)" '0.0.0.0:6160'
assert_eq "$(listen_value 6 6160 no no)" '0.0.0.0:6160'
assert_eq "$(listen_value 6 6160 yes no)" '0.0.0.0:6160'
assert_eq "$(listen_value 6 6160 yes yes)" '0.0.0.0:6160,[::]:6160'
assert_eq "$(render_config 5 6160 keep-this-psk default '0.0.0.0:6160')" \
  '[snell-server]
listen = 0.0.0.0:6160
psk = keep-this-psk
version = 5
tfo = true'
assert_eq "$(render_config 6 6160 keep-this-psk default '0.0.0.0:6160,[::]:6160')" \
  '[snell-server]
listen = 0.0.0.0:6160,[::]:6160
psk = keep-this-psk
version = 6
tfo = true
mode = default'

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
assert_false backup_config "$TEST_TMP/missing-config.conf" >/dev/null 2>&1
NEW_CONFIG="$TEST_TMP/new-config.conf"
write_config_file "$NEW_CONFIG" '' 6 6160 keep-this-psk default '0.0.0.0:6160,[::]:6160'
assert_eq "$(cat "$NEW_CONFIG")" \
  '[snell-server]
listen = 0.0.0.0:6160,[::]:6160
psk = keep-this-psk
version = 6
tfo = true
mode = default'
FAKE_BIN="$TEST_TMP/fake-bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/ip" <<'EOF'
#!/bin/bash
case "$1" in
  -4) printf '%s\n' "${IP4_OUTPUT:-}" ;;
  -6) printf '%s\n' "${IP6_OUTPUT:-}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/ip"

IP6_OUTPUT='1: lo    inet6 ::1/128 scope host
2: eth0  inet6 fe80::1/64 scope link
2: eth0  inet6 fd00::10/64 scope global
2: eth0  inet6 2001:db8::10/64 scope global
2: eth0  inet6 2408:8210::10/64 scope global dynamic'
assert_eq "$(PATH="$FAKE_BIN:$PATH" IP6_OUTPUT="$IP6_OUTPUT" public_ipv6_address)" '2408:8210::10'

IP6_OUTPUT='2: eth0  inet6 2408:8210::20/64 scope global tentative
2: eth0  inet6 2408:8210::21/64 scope global deprecated
2: eth0  inet6 fd00::20/64 scope global'
assert_false env "PATH=$FAKE_BIN:$PATH" "IP6_OUTPUT=$IP6_OUTPUT" SNELL_NODE_NO_MAIN=1 bash -c \
  'source "$1"; public_ipv6_address >/dev/null' bash "$SCRIPT"

cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
source_address=''
while (($#)); do
  if [[ "$1" == --interface ]]; then source_address=$2; shift 2; continue; fi
  shift
done
if [[ -n "${CURL_SUCCESS_ADDRESS:-}" ]]; then
  [[ "$source_address" == "$CURL_SUCCESS_ADDRESS" ]] || exit 28
  printf 'ip=%s\n' "$source_address"
  exit 0
fi
printf '%s\n' "$CURL_OUTPUT"
exit "${CURL_EXIT:-0}"
EOF
chmod +x "$FAKE_BIN/curl"

assert_true env "PATH=$FAKE_BIN:$PATH" 'CURL_OUTPUT=ip=2408:8210::10' SNELL_NODE_NO_MAIN=1 bash -c \
  'source "$1"; ipv6_connectivity 2408:8210::10' bash "$SCRIPT"
assert_false env "PATH=$FAKE_BIN:$PATH" 'CURL_OUTPUT=ip=198.51.100.10' SNELL_NODE_NO_MAIN=1 bash -c \
  'source "$1"; ipv6_connectivity 2408:8210::10' bash "$SCRIPT"
assert_false env "PATH=$FAKE_BIN:$PATH" 'CURL_EXIT=28' SNELL_NODE_NO_MAIN=1 bash -c \
  'source "$1"; ipv6_connectivity 2408:8210::10' bash "$SCRIPT"

IP6_OUTPUT='2: eth0 inet6 2408:8210::30/64 scope global dynamic
2: eth0 inet6 2408:8210::31/64 scope global dynamic'
multi_address_state=$(env "PATH=$FAKE_BIN:$PATH" "IP6_OUTPUT=$IP6_OUTPUT" \
  'CURL_SUCCESS_ADDRESS=2408:8210::31' SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    collect_network_state
    printf "%s|%s|%s" "$IPV6_DETECTED" "$IPV6_CONNECTIVITY" "$PUBLIC_IPV6"
  ' bash "$SCRIPT")
assert_eq "$multi_address_state" 'yes|yes|2408:8210::31'

cat > "$FAKE_BIN/ss" <<'EOF'
#!/bin/bash
case "$*" in
  *-lnt4*) value=${SS_TCP4:-no} ;;
  *-lnu4*) value=${SS_UDP4:-no} ;;
  *-lnt6*) value=${SS_TCP6:-no} ;;
  *-lnu6*) value=${SS_UDP6:-no} ;;
  *) exit 1 ;;
esac
[[ "$value" == yes ]] && printf 'LISTEN 0 4096 socket:%s\n' "$*"
EOF
chmod +x "$FAKE_BIN/ss"

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/bin/bash
[[ -z "${SYSTEMCTL_LOG:-}" ]] || printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
if [[ "$1" == is-active ]]; then
  [[ "${SYSTEMCTL_ACTIVE:-no}" == yes ]] && { [[ "${2:-}" == --quiet ]] || printf 'active\n'; exit 0; }
  [[ "${2:-}" == --quiet ]] || printf 'inactive\n'
  exit 3
fi
exit 0
EOF
chmod +x "$FAKE_BIN/systemctl"

cat > "$FAKE_BIN/journalctl" <<'EOF'
#!/bin/bash
printf 'simulated snell failure\n'
EOF
chmod +x "$FAKE_BIN/journalctl"

cat > "$FAKE_BIN/install" <<'EOF'
#!/bin/bash
[[ "${INSTALL_FAIL:-no}" == yes ]] && exit 73
if [[ "$1" == -d ]]; then
  for target; do :; done
  mkdir -p "$target"
  exit
fi
previous=''
current=''
for argument; do
  previous=$current
  current=$argument
done
cp "$previous" "$current"
EOF
chmod +x "$FAKE_BIN/install"

MISSING_REWRITE_CONFIG="$TEST_TMP/missing-rewrite.conf"
assert_false env "PATH=$FAKE_BIN:$PATH" SNELL_NODE_NO_MAIN=1 bash -c '
  source "$1"
  rewrite_config_file "$2" 6 "0.0.0.0:6160,[::]:6160" default
' bash "$SCRIPT" "$MISSING_REWRITE_CONFIG" 2>/dev/null
[[ ! -e "$MISSING_REWRITE_CONFIG" ]] || fail 'failed config read created a replacement config'

assert_true env "PATH=$FAKE_BIN:$PATH" SS_TCP4=yes SS_UDP4=yes SS_TCP6=no SS_UDP6=no \
  SYSTEMCTL_ACTIVE=yes SNELL_NODE_NO_MAIN=1 bash -c \
  'source "$1"; validate_runtime 5 6160 "0.0.0.0:6160"' bash "$SCRIPT"
assert_true env "PATH=$FAKE_BIN:$PATH" SS_TCP4=yes SS_UDP4=yes SS_TCP6=no SS_UDP6=no \
  SYSTEMCTL_ACTIVE=yes SNELL_NODE_NO_MAIN=1 bash -c \
  'source "$1"; validate_runtime 6 6160 "0.0.0.0:6160"' bash "$SCRIPT"
assert_false env "PATH=$FAKE_BIN:$PATH" SS_TCP4=yes SS_UDP4=yes SS_TCP6=yes SS_UDP6=no \
  SYSTEMCTL_ACTIVE=yes SNELL_NODE_NO_MAIN=1 bash -c \
  'source "$1"; validate_runtime 6 6160 "0.0.0.0:6160,[::]:6160"' bash "$SCRIPT"
assert_true env "PATH=$FAKE_BIN:$PATH" SS_TCP4=yes SS_UDP4=yes SS_TCP6=yes SS_UDP6=yes \
  SYSTEMCTL_ACTIVE=yes SNELL_NODE_NO_MAIN=1 bash -c \
  'source "$1"; validate_runtime 6 6160 "0.0.0.0:6160,[::]:6160"' bash "$SCRIPT"

IP4_OUTPUT='2: eth0 inet 192.0.2.10/24 scope global eth0'
IP6_OUTPUT='2: eth0 inet6 2408:8210::10/64 scope global dynamic'
status_output=$(env "PATH=$FAKE_BIN:$PATH" "IP4_OUTPUT=$IP4_OUTPUT" "IP6_OUTPUT=$IP6_OUTPUT" \
  'CURL_OUTPUT=ip=2408:8210::10' SS_TCP4=yes SS_UDP4=yes SS_TCP6=yes SS_UDP6=yes \
  SYSTEMCTL_ACTIVE=yes SNELL_NODE_NO_MAIN=1 bash -c \
  'source "$1"; status_report 6 6160 "0.0.0.0:6160,[::]:6160"' bash "$SCRIPT")
assert_contains "$status_output" 'Snell version: v6'
assert_contains "$status_output" 'IPv4 detected: yes'
assert_contains "$status_output" 'IPv6 detected: yes'
assert_contains "$status_output" 'IPv6 connectivity: yes'
assert_contains "$status_output" 'Listen mode: Dual-stack'
assert_contains "$status_output" 'TCP IPv4 listening: yes'
assert_contains "$status_output" 'TCP IPv6 listening: yes'
assert_contains "$status_output" 'UDP IPv4 listening: yes'
assert_contains "$status_output" 'UDP IPv6 listening: yes'
assert_contains "$status_output" 'Service status: active'

CONFIG_FIXTURE="$TEST_TMP/config.conf"
cat > "$CONFIG_FIXTURE" <<'EOF'
[snell-server]
listen = 0.0.0.0:6160
psk = keep-this-psk
version = 5
tfo = true
custom-option = keep-this-value
EOF
original_config=$(cat "$CONFIG_FIXTURE")
assert_eq "$(config_value "$CONFIG_FIXTURE" listen)" '0.0.0.0:6160'
assert_eq "$(config_value "$CONFIG_FIXTURE" version)" '5'
assert_eq "$(listen_port '0.0.0.0:6160,[::]:6160')" '6160'
config_backup=$(backup_config "$CONFIG_FIXTURE")
[[ -f "$config_backup" ]] || fail 'config backup was not created'
assert_eq "$(cat "$config_backup")" "$original_config"

INSTALL_FAILURE_CONFIG="$TEST_TMP/install-failure.conf"
cp "$config_backup" "$INSTALL_FAILURE_CONFIG"
assert_false env "PATH=$FAKE_BIN:$PATH" INSTALL_FAIL=yes SNELL_NODE_NO_MAIN=1 bash -c '
  source "$1"
  rewrite_config_file "$2" 6 "0.0.0.0:6160,[::]:6160" default
' bash "$SCRIPT" "$INSTALL_FAILURE_CONFIG"
assert_eq "$(cat "$INSTALL_FAILURE_CONFIG")" "$original_config"

rewrite_config_file "$CONFIG_FIXTURE" 6 '0.0.0.0:6160,[::]:6160' default
rewritten_config=$(cat "$CONFIG_FIXTURE")
assert_contains "$rewritten_config" 'listen = 0.0.0.0:6160,[::]:6160'
assert_contains "$rewritten_config" 'psk = keep-this-psk'
assert_contains "$rewritten_config" 'version = 6'
assert_contains "$rewritten_config" 'mode = default'
assert_contains "$rewritten_config" 'custom-option = keep-this-value'

DOWNGRADE_CONFIG="$TEST_TMP/downgrade.conf"
cp "$CONFIG_FIXTURE" "$DOWNGRADE_CONFIG"
rewrite_config_file "$DOWNGRADE_CONFIG" 5 '0.0.0.0:6160' default
downgraded_config=$(cat "$DOWNGRADE_CONFIG")
assert_contains "$downgraded_config" 'listen = 0.0.0.0:6160'
assert_contains "$downgraded_config" 'version = 5'
[[ "$downgraded_config" != *'mode ='* ]] || fail 'v5 config retained the v6-only mode setting'

cp "$config_backup" "$CONFIG_FIXTURE"
BINARY_FIXTURE="$TEST_TMP/snell-server"
BINARY_BACKUP="$TEST_TMP/snell-server.previous"
printf 'new binary\n' > "$BINARY_FIXTURE"
printf 'old binary\n' > "$BINARY_BACKUP"
SYSTEMCTL_LOG="$TEST_TMP/systemctl.log"
: > "$SYSTEMCTL_LOG"
if env "PATH=$FAKE_BIN:$PATH" SS_TCP4=yes SS_UDP4=yes SS_TCP6=yes SS_UDP6=no \
  SYSTEMCTL_ACTIVE=yes "SYSTEMCTL_LOG=$SYSTEMCTL_LOG" SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    activate_runtime_change "$2" "$3" 6 6160 "0.0.0.0:6160,[::]:6160" default "$4" "$5"
  ' bash "$SCRIPT" "$CONFIG_FIXTURE" "$config_backup" "$BINARY_FIXTURE" "$BINARY_BACKUP"; then
  fail 'runtime change unexpectedly succeeded without UDP IPv6 listener'
fi
assert_eq "$(cat "$CONFIG_FIXTURE")" "$original_config"
assert_eq "$(cat "$BINARY_FIXTURE")" 'old binary'
restart_count=$(grep -c '^restart snell-node$' "$SYSTEMCTL_LOG")
assert_eq "$restart_count" 2
rollback_validation_count=$(grep -c '^is-active --quiet snell-node$' "$SYSTEMCTL_LOG")
assert_eq "$rollback_validation_count" 2

cp "$config_backup" "$CONFIG_FIXTURE"
printf 'new binary\n' > "$BINARY_FIXTURE"
printf 'old binary\n' > "$BINARY_BACKUP"
: > "$SYSTEMCTL_LOG"
set +e
env "PATH=$FAKE_BIN:$PATH" SS_TCP4=no SS_UDP4=no SS_TCP6=no SS_UDP6=no \
  SYSTEMCTL_ACTIVE=no "SYSTEMCTL_LOG=$SYSTEMCTL_LOG" SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    activate_runtime_change "$2" "$3" 6 6160 "0.0.0.0:6160,[::]:6160" default "$4" "$5"
  ' bash "$SCRIPT" "$CONFIG_FIXTURE" "$config_backup" "$BINARY_FIXTURE" "$BINARY_BACKUP"
rollback_failure_rc=$?
set -e
assert_eq "$rollback_failure_rc" 2
assert_eq "$(cat "$CONFIG_FIXTURE")" "$original_config"
assert_eq "$(cat "$BINARY_FIXTURE")" 'old binary'

cp "$config_backup" "$CONFIG_FIXTURE"
printf 'new binary\n' > "$BINARY_FIXTURE"
rm -f "$BINARY_BACKUP"
: > "$SYSTEMCTL_LOG"
set +e
env "PATH=$FAKE_BIN:$PATH" SS_TCP4=yes SS_UDP4=yes SS_TCP6=yes SS_UDP6=no \
  SYSTEMCTL_ACTIVE=yes "SYSTEMCTL_LOG=$SYSTEMCTL_LOG" SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    activate_runtime_change "$2" "$3" 6 6160 "0.0.0.0:6160,[::]:6160" default "$4" "$5"
  ' bash "$SCRIPT" "$CONFIG_FIXTURE" "$config_backup" "$BINARY_FIXTURE" "$BINARY_BACKUP"
missing_binary_backup_rc=$?
set -e
assert_eq "$missing_binary_backup_rc" 2
assert_eq "$(cat "$CONFIG_FIXTURE")" "$original_config"
assert_eq "$(cat "$BINARY_FIXTURE")" 'new binary'

V5_REPAIR_CONFIG="$TEST_TMP/v5-repair.conf"
cp "$config_backup" "$V5_REPAIR_CONFIG"
: > "$SYSTEMCTL_LOG"
v5_repair_output=$(env "PATH=$FAKE_BIN:$PATH" "IP4_OUTPUT=$IP4_OUTPUT" "IP6_OUTPUT=$IP6_OUTPUT" \
  'CURL_OUTPUT=ip=2408:8210::10' SS_TCP4=yes SS_UDP4=yes SS_TCP6=no SS_UDP6=no \
  SYSTEMCTL_ACTIVE=yes "SYSTEMCTL_LOG=$SYSTEMCTL_LOG" SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    repair_dualstack_node "$2" ""
  ' bash "$SCRIPT" "$V5_REPAIR_CONFIG")
assert_eq "$(cat "$V5_REPAIR_CONFIG")" "$original_config"
assert_contains "$v5_repair_output" 'Snell v5'
assert_contains "$v5_repair_output" '未修改配置'
assert_eq "$(grep -c '^restart snell-node$' "$SYSTEMCTL_LOG" || true)" 0
if inactive_repair_output=$(env "PATH=$FAKE_BIN:$PATH" "IP4_OUTPUT=$IP4_OUTPUT" "IP6_OUTPUT=$IP6_OUTPUT" \
  'CURL_OUTPUT=ip=2408:8210::10' SS_TCP4=no SS_UDP4=no SS_TCP6=no SS_UDP6=no \
  SYSTEMCTL_ACTIVE=no SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    repair_dualstack_node "$2" ""
  ' bash "$SCRIPT" "$V5_REPAIR_CONFIG" 2>&1); then
  fail 'v5 repair reported success while the existing service was inactive'
fi
assert_contains "$inactive_repair_output" 'simulated snell failure'

V6_REPAIR_CONFIG="$TEST_TMP/v6-repair.conf"
render_config 6 6160 keep-this-psk default '0.0.0.0:6160' > "$V6_REPAIR_CONFIG"
: > "$SYSTEMCTL_LOG"
v6_repair_output=$(env "PATH=$FAKE_BIN:$PATH" "IP4_OUTPUT=$IP4_OUTPUT" "IP6_OUTPUT=$IP6_OUTPUT" \
  'CURL_OUTPUT=ip=2408:8210::10' SS_TCP4=yes SS_UDP4=yes SS_TCP6=yes SS_UDP6=yes \
  SYSTEMCTL_ACTIVE=yes "SYSTEMCTL_LOG=$SYSTEMCTL_LOG" SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    repair_dualstack_node "$2" ""
  ' bash "$SCRIPT" "$V6_REPAIR_CONFIG")
v6_repaired_config=$(cat "$V6_REPAIR_CONFIG")
assert_contains "$v6_repaired_config" 'listen = 0.0.0.0:6160,[::]:6160'
assert_contains "$v6_repaired_config" 'psk = keep-this-psk'
assert_contains "$v6_repair_output" '已完成原地双栈修复'
restart_count=$(grep -c '^restart snell-node$' "$SYSTEMCTL_LOG")
assert_eq "$restart_count" 1
backup_count=$(find "$TEST_TMP" -maxdepth 1 -name 'v6-repair.conf.bak-*' | wc -l | tr -d ' ')
assert_eq "$backup_count" 1

help_output=$(SNELL_NODE_NO_MAIN=0 bash "$SCRIPT" help)
assert_contains "$help_output" 'repair-dualstack'
status_output=$(env "PATH=$FAKE_BIN:$PATH" "IP4_OUTPUT=$IP4_OUTPUT" "IP6_OUTPUT=$IP6_OUTPUT" \
  'CURL_OUTPUT=ip=2408:8210::10' SS_TCP4=yes SS_UDP4=yes SS_TCP6=yes SS_UDP6=yes \
  SYSTEMCTL_ACTIVE=yes SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    status_node "$2"
  ' bash "$SCRIPT" "$V6_REPAIR_CONFIG")
assert_contains "$status_output" 'Snell version: v6'
assert_contains "$status_output" 'Listen mode: Dual-stack'
assert_contains "$status_output" 'Service status: active'

LIFECYCLE_ROOT="$TEST_TMP/lifecycle-root"
LIFECYCLE_SCRIPT="$TEST_TMP/snell-node-lifecycle.sh"
mkdir -p "$LIFECYCLE_ROOT/etc/systemd/system" "$LIFECYCLE_ROOT/usr/local/bin"
sed \
  -e "s|readonly DIR='/etc/snell-node'|readonly DIR='$LIFECYCLE_ROOT/etc/snell-node'|" \
  -e "s|readonly BIN='/usr/local/bin/snell-server'|readonly BIN='$LIFECYCLE_ROOT/usr/local/bin/snell-server'|" \
  -e "s|/etc/systemd/system|$LIFECYCLE_ROOT/etc/systemd/system|g" \
  "$SCRIPT" > "$LIFECYCLE_SCRIPT"
: > "$SYSTEMCTL_LOG"
env "PATH=$FAKE_BIN:$PATH" SS_TCP4=yes SS_UDP4=yes SS_TCP6=no SS_UDP6=no \
  SYSTEMCTL_ACTIVE=yes "SYSTEMCTL_LOG=$SYSTEMCTL_LOG" SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    require_systemd_linux() { :; }
    install_dependencies() { :; }
    prepare_dir() { install -d -m 0750 "$DIR"; }
    download_binary() { printf "snell-v5-binary\n" > "$BIN.new"; chmod 0755 "$BIN.new"; }
    collect_network_state() {
      IPV4_DETECTED=yes
      IPV6_DETECTED=yes
      IPV6_CONNECTIVITY=yes
      PUBLIC_IPV6=2408:8210::10
    }
    ask() {
      case "$1" in
        *"连接地址"*) printf "snell.example.com" ;;
        *"端口"*) printf "6160" ;;
        *"模式"*) printf "default" ;;
        *) return 1 ;;
      esac
    }
    port_free() { return 0; }
    random_psk() { printf "lifecycle-test-psk"; }
    chown() { :; }
    userdel() { :; }

    install_node 5
    cp "$CONFIG" "$2/config-after-install.conf"
    cp "$META" "$2/meta-after-install.env"
    cp "$2/etc/systemd/system/$UNIT.service" "$2/service-after-install.service"
    if (install_node 5 >/dev/null 2>&1); then
      exit 90
    fi
    uninstall_node <<< "y"
    install_node 5 >/dev/null
    cp "$CONFIG" "$2/config-after-reinstall.conf"
    uninstall_node <<< "y"
  ' bash "$LIFECYCLE_SCRIPT" "$LIFECYCLE_ROOT"

lifecycle_config=$(cat "$LIFECYCLE_ROOT/config-after-install.conf")
assert_contains "$lifecycle_config" 'listen = 0.0.0.0:6160'
[[ "$lifecycle_config" != *'[::]'* ]] || fail 'v5 install used the v6-only dual-listen syntax'
assert_contains "$lifecycle_config" 'psk = lifecycle-test-psk'
assert_contains "$lifecycle_config" 'version = 5'
reinstall_config=$(cat "$LIFECYCLE_ROOT/config-after-reinstall.conf")
assert_contains "$reinstall_config" 'listen = 0.0.0.0:6160'
assert_contains "$reinstall_config" 'version = 5'
lifecycle_meta=$(cat "$LIFECYCLE_ROOT/meta-after-install.env")
assert_contains "$lifecycle_meta" 'PORT=6160'
assert_contains "$lifecycle_meta" 'PSK=lifecycle-test-psk'
lifecycle_service=$(cat "$LIFECYCLE_ROOT/service-after-install.service")
assert_contains "$lifecycle_service" 'User=snell-node'
assert_contains "$lifecycle_service" 'Group=snell-node'
assert_contains "$lifecycle_service" 'Restart=on-failure'
assert_contains "$lifecycle_service" "ExecStart=$LIFECYCLE_ROOT/usr/local/bin/snell-server -c $LIFECYCLE_ROOT/etc/snell-node/config.conf"
assert_eq "$(grep -c '^enable --now snell-node$' "$SYSTEMCTL_LOG")" 2
assert_eq "$(grep -c '^disable --now snell-node$' "$SYSTEMCTL_LOG")" 2
[[ ! -e "$LIFECYCLE_ROOT/etc/snell-node" ]] || fail 'uninstall left the Snell config directory behind'
[[ ! -e "$LIFECYCLE_ROOT/usr/local/bin/snell-server" ]] || fail 'uninstall left the Snell binary behind'
[[ ! -e "$LIFECYCLE_ROOT/etc/systemd/system/snell-node.service" ]] || fail 'uninstall left the systemd unit behind'

UPDATE_ROOT="$TEST_TMP/update-root"
UPDATE_SCRIPT="$TEST_TMP/snell-node-update.sh"
mkdir -p "$UPDATE_ROOT/etc/snell-node" "$UPDATE_ROOT/usr/local/bin"
sed \
  -e "s|readonly DIR='/etc/snell-node'|readonly DIR='$UPDATE_ROOT/etc/snell-node'|" \
  -e "s|readonly BIN='/usr/local/bin/snell-server'|readonly BIN='$UPDATE_ROOT/usr/local/bin/snell-server'|" \
  "$SCRIPT" > "$UPDATE_SCRIPT"
cat > "$UPDATE_ROOT/etc/snell-node/config.conf" <<'EOF'
[snell-server]
listen = 0.0.0.0:6160
psk = update-test-psk
version = 5
tfo = true
custom-option = keep-this-value
EOF
cat > "$UPDATE_ROOT/etc/snell-node/meta.env" <<'EOF'
VERSION=5
HOST=snell.example.com
PORT=6262
PSK=stale-meta-psk
MODE=default
EOF
printf 'snell-v5-binary\n' > "$UPDATE_ROOT/usr/local/bin/snell-server"
: > "$SYSTEMCTL_LOG"
env "PATH=$FAKE_BIN:$PATH" SS_TCP4=yes SS_UDP4=yes SS_TCP6=yes SS_UDP6=yes \
  SYSTEMCTL_ACTIVE=yes "SYSTEMCTL_LOG=$SYSTEMCTL_LOG" SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    require_systemd_linux() { :; }
    install_dependencies() { :; }
    download_binary() { printf "snell-v6-binary\n" > "$BIN.new"; chmod 0755 "$BIN.new"; }
    collect_network_state() {
      IPV4_DETECTED=yes
      IPV6_DETECTED=yes
      IPV6_CONNECTIVITY=yes
      PUBLIC_IPV6=2408:8210::10
    }
    chown() { :; }
    update_node 6
  ' bash "$UPDATE_SCRIPT"

updated_config=$(cat "$UPDATE_ROOT/etc/snell-node/config.conf")
assert_contains "$updated_config" 'listen = 0.0.0.0:6160,[::]:6160'
assert_contains "$updated_config" 'psk = update-test-psk'
assert_contains "$updated_config" 'version = 6'
assert_contains "$updated_config" 'custom-option = keep-this-value'
updated_meta=$(cat "$UPDATE_ROOT/etc/snell-node/meta.env")
assert_contains "$updated_meta" 'VERSION=6'
assert_contains "$updated_meta" 'PORT=6160'
assert_contains "$updated_meta" 'PSK=update-test-psk'
assert_eq "$(cat "$UPDATE_ROOT/usr/local/bin/snell-server")" 'snell-v6-binary'
assert_eq "$(grep -c '^restart snell-node$' "$SYSTEMCTL_LOG")" 1
update_backup_count=$(find "$UPDATE_ROOT/etc/snell-node" -maxdepth 1 -name 'config.conf.bak-*' | wc -l | tr -d ' ')
assert_eq "$update_backup_count" 1

printf 'PASS: Snell lifecycle, IPv6 policy, runtime validation, config backup, and rollback\n'
