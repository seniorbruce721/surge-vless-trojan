#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/vless-node.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "expected output not to contain [$2], got [$1]"; }

[[ -f "$SCRIPT" ]] || fail 'vless-node.sh is missing'

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
write_os_release "$TEST_TMP/ubuntu-2204" ubuntu 22.04 'Ubuntu 22.04 LTS'
write_os_release "$TEST_TMP/ubuntu-2404" ubuntu 24.04 'Ubuntu 24.04 LTS'
write_os_release "$TEST_TMP/fedora-43" fedora 43 'Fedora Linux 43'

for fixture in debian-12 debian-13 ubuntu-2204 ubuntu-2404; do
  OS_RELEASE_FILE="$TEST_TMP/$fixture" VLESS_NODE_NO_MAIN=1 /bin/bash -c '
    source "$1"
    uname() { case "$1" in -s) printf "Linux\n" ;; -m) printf "x86_64\n" ;; esac; }
    command() { [[ "$1" == -v && "$2" == systemctl ]]; }
    require_supported_host
  ' bash "$SCRIPT"
done

if unsupported_output=$(OS_RELEASE_FILE="$TEST_TMP/fedora-43" VLESS_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  uname() { case "$1" in -s) printf "Linux\n" ;; -m) printf "x86_64\n" ;; esac; }
  command() { [[ "$1" == -v && "$2" == systemctl ]]; }
  require_supported_host
' bash "$SCRIPT" 2>&1); then
  fail 'unsupported Fedora host was accepted'
fi
assert_contains "$unsupported_output" '仅支持 Debian 12/13 和 Ubuntu 22.04/24.04'

mode_for() {
  VLESS_NODE_NO_MAIN=1 /bin/bash -c '
    source "$1"
    network_mode_from_capabilities "$2" "$3" "$4"
  ' bash "$SCRIPT" "$1" "$2" "$3"
}

assert_eq "$(mode_for yes no no)" ipv4
assert_eq "$(mode_for no yes no)" ipv6
assert_eq "$(mode_for yes yes yes)" dual-single
assert_eq "$(mode_for yes yes no)" dual-split
if mode_output=$(mode_for no no no 2>&1); then
  fail 'host without a verified public address family was accepted'
fi
assert_contains "$mode_output" '未检测到可用的公网 IPv4 或 IPv6'

CONFIG_DIR="$TEST_TMP/configs"
mkdir -p "$CONFIG_DIR"
for mode in ipv4 ipv6 dual-single dual-split; do
  VLESS_NODE_NO_MAIN=1 /bin/bash -c '
    source "$1"
    render_config "$2" 24443 2cae91b3-f85c-433b-88ee-a002b9ed6d61 \
      server-private-key 0123456789abcdef reality.example.com
  ' bash "$SCRIPT" "$mode" > "$CONFIG_DIR/$mode.json"
done

python3 - "$CONFIG_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "ipv4": ["0.0.0.0"],
    "ipv6": ["::"],
    "dual-single": ["::"],
    "dual-split": ["0.0.0.0", "::"],
}

for mode, listens in expected.items():
    config = json.loads((root / f"{mode}.json").read_text())
    assert len(config["inbounds"]) == len(listens)
    assert [item["listen"] for item in config["inbounds"]] == listens
    for inbound in config["inbounds"]:
        assert inbound["protocol"] == "vless"
        assert inbound["port"] == 24443
        assert inbound["settings"]["clients"] == [{
            "id": "2cae91b3-f85c-433b-88ee-a002b9ed6d61",
            "flow": "xtls-rprx-vision",
        }]
        assert inbound["settings"]["decryption"] == "none"
        stream = inbound["streamSettings"]
        assert stream["method"] == "raw"
        assert stream["security"] == "reality"
        reality = stream["realitySettings"]
        assert reality["target"] == "reality.example.com:443"
        assert reality["serverNames"] == ["reality.example.com"]
        assert reality["privateKey"] == "server-private-key"
        assert reality["shortIds"] == ["0123456789abcdef"]
    rendered = (root / f"{mode}.json").read_text().lower()
    assert "websocket" not in rendered
    assert "grpc" not in rendered
PY

connections=$(VLESS_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  render_connection_info 203.0.113.23 2001:db8::23 node.example.com dual 24443 \
    2cae91b3-f85c-433b-88ee-a002b9ed6d61 server-public-key \
    0123456789abcdef reality.example.com
' bash "$SCRIPT")

assert_contains "$connections" '服务器 IPv4：203.0.113.23'
assert_contains "$connections" '服务器 IPv6：2001:db8::23'
assert_contains "$connections" '服务器域名：node.example.com'
assert_contains "$connections" '端口：24443'
assert_contains "$connections" 'UUID：2cae91b3-f85c-433b-88ee-a002b9ed6d61'
assert_contains "$connections" 'SNI：reality.example.com'
assert_contains "$connections" 'REALITY Public Key：server-public-key'
assert_contains "$connections" 'Short ID：0123456789abcdef'
assert_contains "$connections" 'Surge [Proxy] / Proxy.dconf'
assert_contains "$connections" 'Personal-VLESS-IPv4 = vless, 203.0.113.23, 24443, username=2cae91b3-f85c-433b-88ee-a002b9ed6d61, flow=xtls-rprx-vision, sni=reality.example.com, reality-public-key=server-public-key, reality-short-id=0123456789abcdef'
assert_contains "$connections" 'Personal-VLESS-IPv6 = vless, 2001:db8::23, 24443, username=2cae91b3-f85c-433b-88ee-a002b9ed6d61'
assert_contains "$connections" 'Personal-VLESS-Domain = vless, node.example.com, 24443, username=2cae91b3-f85c-433b-88ee-a002b9ed6d61'
assert_contains "$connections" 'ip-version=dual'
assert_not_contains "$connections" 'server-private-key'

ipv6_connections=$(VLESS_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  render_connection_info "" 2001:db8::23 v6.example.com v6-only 24443 \
    2cae91b3-f85c-433b-88ee-a002b9ed6d61 server-public-key \
    0123456789abcdef reality.example.com
' bash "$SCRIPT")
assert_not_contains "$ipv6_connections" 'Personal-VLESS-IPv4'
assert_contains "$ipv6_connections" 'Personal-VLESS-IPv6'
assert_contains "$ipv6_connections" 'Personal-VLESS-Domain = vless, v6.example.com, 24443'
assert_contains "$ipv6_connections" 'ip-version=v6-only'

chooser_output=$(PROBE_LOG="$TEST_TMP/probe.log" VLESS_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  probe_candidate_mode() {
    printf "%s\n" "$1" >> "$PROBE_LOG"
    [[ "$1" == dual-split ]]
  }
  choose_validated_listen_mode yes yes /fake/xray 24443 \
    fake-uuid fake-private fake-short-id reality.example.com
' bash "$SCRIPT")
assert_eq "$chooser_output" dual-split
assert_eq "$(cat "$TEST_TMP/probe.log")" $'dual-single\ndual-split'

IPV6_PROBE_LOG="$TEST_TMP/ipv6-probe.log"
ipv6_mode=$(PROBE_LOG="$IPV6_PROBE_LOG" VLESS_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  probe_candidate_mode() { printf "%s\n" "$1" >> "$PROBE_LOG"; [[ "$1" == ipv6 ]]; }
  choose_validated_listen_mode no yes /fake/xray 24443 \
    fake-uuid fake-private fake-short-id reality.example.com
' bash "$SCRIPT")
assert_eq "$ipv6_mode" ipv6
assert_eq "$(cat "$IPV6_PROBE_LOG")" ipv6

identity_output=$(VLESS_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  fake_xray() {
    case "$1" in
      uuid) printf "2cae91b3-f85c-433b-88ee-a002b9ed6d61\n" ;;
      x25519) printf "Private key: current-private\nPublic key: current-public\n" ;;
    esac
  }
  openssl() { printf "0123456789abcdef\n"; }
  generate_identity fake_xray
  printf "%s|%s|%s|%s" "$UUID" "$PRIVATE_KEY" "$PUBLIC_KEY" "$SHORT_ID"
' bash "$SCRIPT")
assert_eq "$identity_output" '2cae91b3-f85c-433b-88ee-a002b9ed6d61|current-private|current-public|0123456789abcdef'

release_asset_output=$(VLESS_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  curl() {
    printf '\''{"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://github.com/XTLS/Xray-core/releases/download/v1/Xray-linux-64.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'\''
  }
  release_asset XTLS/Xray-core Xray-linux-64.zip
' bash "$SCRIPT")
assert_eq "$release_asset_output" 'https://github.com/XTLS/Xray-core/releases/download/v1/Xray-linux-64.zip|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

if no_digest_output=$(VLESS_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  curl() { printf '\''{"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/xray.zip","digest":null}]}'\''; }
  release_asset XTLS/Xray-core Xray-linux-64.zip
' bash "$SCRIPT" 2>&1); then
  fail 'release asset without an official SHA-256 digest was accepted'
fi

INSTALL_ROOT="$TEST_TMP/install-root"
INSTALL_BIN="$TEST_TMP/install-bin"
INSTALL_LOG="$TEST_TMP/install-calls.log"
mkdir -p "$INSTALL_ROOT/etc/systemd/system" "$INSTALL_ROOT/etc/snell-node" \
  "$INSTALL_ROOT/etc/surge-node" "$INSTALL_ROOT/usr/local/lib" "$INSTALL_BIN"
printf 'snell-preserved\n' > "$INSTALL_ROOT/etc/snell-node/sentinel"
printf 'trojan-preserved\n' > "$INSTALL_ROOT/etc/surge-node/sentinel"

cat > "$INSTALL_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl:%s\n' "$*" >> "$INSTALL_LOG"
case "$1" in
  is-active|is-enabled) exit 0 ;;
  show) printf '0\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$INSTALL_BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$INSTALL_BIN/nc" <<'EOF'
#!/usr/bin/env bash
printf 'nc:%s\n' "$*" >> "$INSTALL_LOG"
exit 0
EOF
cat > "$INSTALL_BIN/getent" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ahostsv4) printf '203.0.113.23 STREAM node.example.com\n' ;;
  ahostsv6) printf '2001:db8::23 STREAM node.example.com\n' ;;
  *) exit 1 ;;
esac
EOF
cat > "$INSTALL_BIN/ufw" <<'EOF'
#!/usr/bin/env bash
printf 'ufw:%s\n' "$*" >> "$INSTALL_LOG"
printf 'Status: inactive\n'
EOF
chmod +x "$INSTALL_BIN"/*

install_output=$(env \
  PATH="$INSTALL_BIN:/usr/bin:/bin" \
  INSTALL_LOG="$INSTALL_LOG" \
  VLESS_NODE_DIR="$INSTALL_ROOT/etc/vless-node" \
  VLESS_NODE_BIN_DIR="$INSTALL_ROOT/usr/local/lib/vless-node" \
  VLESS_NODE_UNIT_DIR="$INSTALL_ROOT/etc/systemd/system" \
  VLESS_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    require_supported_host() { :; }
    install_dependencies() { :; }
    ensure_service_user() { :; }
    chown() { :; }
    interactive_terminal() { return 0; }
    collect_network_state() {
      IPV4_PUBLIC=yes
      IPV6_PUBLIC=yes
      PUBLIC_IPV4=203.0.113.23
      PUBLIC_IPV6=2001:db8::23
      IPV4_REASON=ok
      IPV6_REASON=ok
    }
    ask() {
      case "$1" in
        *"端口"*) printf "24443" ;;
        *"SNI"*) printf "reality.example.com" ;;
        *"连接域名"*) printf "node.example.com" ;;
        *) return 1 ;;
      esac
    }
    download_xray_to() {
      cat > "$1" <<"XRAY"
#!/usr/bin/env bash
case "$1" in
  uuid) printf "2cae91b3-f85c-433b-88ee-a002b9ed6d61\n" ;;
  x25519) printf "PrivateKey: server-private-key\nPassword: server-public-key\n" ;;
  tls) exit 0 ;;
  run) exit 0 ;;
  version) printf "Xray test\n" ;;
  *) exit 0 ;;
esac
XRAY
      chmod +x "$1"
    }
    probe_candidate_mode() { [[ "$1" == dual-split ]]; }
    install_node
  ' bash "$SCRIPT")

assert_contains "$install_output" '服务器 IPv4：203.0.113.23'
assert_contains "$install_output" '服务器 IPv6：2001:db8::23'
assert_contains "$install_output" 'Personal-VLESS-Domain = vless, node.example.com, 24443'
assert_contains "$install_output" '本地服务已验证；公网入站仍需在 Surge 上实测'
[[ -x "$INSTALL_ROOT/usr/local/lib/vless-node/xray" ]] || fail 'install did not place the isolated Xray binary'
[[ -f "$INSTALL_ROOT/etc/systemd/system/vless-node.service" ]] || fail 'install did not create its systemd unit'
[[ -f "$INSTALL_ROOT/etc/vless-node/config.json" ]] || fail 'install did not create config.json'
assert_contains "$(cat "$INSTALL_ROOT/etc/vless-node/meta.env")" 'LISTEN_MODE=dual-split'
assert_contains "$(cat "$INSTALL_ROOT/etc/vless-node/meta.env")" 'MANAGED_BY=vless-node.sh'
assert_contains "$(cat "$INSTALL_ROOT/etc/vless-node/connections.txt")" 'Personal-VLESS-IPv6'
assert_contains "$(cat "$INSTALL_ROOT/etc/systemd/system/vless-node.service")" 'User=vless-node'
assert_contains "$(cat "$INSTALL_ROOT/etc/systemd/system/vless-node.service")" "$INSTALL_ROOT/usr/local/lib/vless-node/xray run -config"
assert_eq "$(stat -f '%Lp' "$INSTALL_ROOT/etc/vless-node")" 750
assert_eq "$(stat -f '%Lp' "$INSTALL_ROOT/etc/vless-node/config.json")" 640
assert_eq "$(cat "$INSTALL_ROOT/etc/snell-node/sentinel")" 'snell-preserved'
assert_eq "$(cat "$INSTALL_ROOT/etc/surge-node/sentinel")" 'trojan-preserved'
assert_not_contains "$(cat "$INSTALL_LOG")" 'ufw:allow'
assert_not_contains "$(cat "$INSTALL_LOG")" 'ufw:delete'

show_output=$(env \
  VLESS_NODE_DIR="$INSTALL_ROOT/etc/vless-node" \
  VLESS_NODE_BIN_DIR="$INSTALL_ROOT/usr/local/lib/vless-node" \
  VLESS_NODE_UNIT_DIR="$INSTALL_ROOT/etc/systemd/system" \
  VLESS_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    interactive_terminal() { return 0; }
    show_node
  ' bash "$SCRIPT")
assert_eq "$show_output" "$(cat "$INSTALL_ROOT/etc/vless-node/connections.txt")"

FAIL_ROOT="$TEST_TMP/fail-root"
FAIL_TMP="$TEST_TMP/fail-tmp"
mkdir -p "$FAIL_ROOT/etc/systemd/system" "$FAIL_ROOT/usr/local/lib" "$FAIL_TMP"
if finalize_failure_output=$(env \
  PATH="$INSTALL_BIN:/usr/bin:/bin" \
  TMPDIR="$FAIL_TMP" \
  INSTALL_LOG="$INSTALL_LOG" \
  VLESS_NODE_DIR="$FAIL_ROOT/etc/vless-node" \
  VLESS_NODE_BIN_DIR="$FAIL_ROOT/usr/local/lib/vless-node" \
  VLESS_NODE_UNIT_DIR="$FAIL_ROOT/etc/systemd/system" \
  VLESS_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    require_supported_host() { :; }
    install_dependencies() { :; }
    ensure_service_user() { :; }
    interactive_terminal() { return 0; }
    collect_network_state() {
      IPV4_PUBLIC=yes; IPV6_PUBLIC=no
      PUBLIC_IPV4=203.0.113.23; PUBLIC_IPV6=""
      IPV4_REASON=ok; IPV6_REASON=unavailable
    }
    ask() {
      case "$1" in
        *"端口"*) printf "24443" ;;
        *"SNI"*) printf "reality.example.com" ;;
        *"连接域名"*) printf "" ;;
      esac
    }
    download_xray_to() {
      cat > "$1" <<"XRAY"
#!/usr/bin/env bash
case "$1" in
  uuid) printf "2cae91b3-f85c-433b-88ee-a002b9ed6d61\n" ;;
  x25519) printf "Private key: server-private-key\nPublic key: server-public-key\n" ;;
  *) exit 0 ;;
esac
XRAY
      chmod +x "$1"
    }
    probe_candidate_mode() { [[ "$1" == ipv4 ]]; }
    chown() { return 1; }
    install_node
  ' bash "$SCRIPT" 2>&1); then
  fail 'install unexpectedly succeeded after finalization failure'
fi
[[ ! -e "$FAIL_ROOT/etc/vless-node" ]] || fail 'failed install left its config directory'
[[ ! -e "$FAIL_ROOT/usr/local/lib/vless-node" ]] || fail 'failed install left its binary directory'
[[ ! -e "$FAIL_ROOT/etc/systemd/system/vless-node.service" ]] || fail 'failed install left its unit'
[[ -z "$(find "$FAIL_TMP" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'failed install left a temporary directory'

COLLISION_ROOT="$TEST_TMP/collision-root"
mkdir -p "$COLLISION_ROOT/etc/vless-node" "$COLLISION_ROOT/etc/systemd/system" "$COLLISION_ROOT/usr/local/lib"
printf 'keep-existing\n' > "$COLLISION_ROOT/etc/vless-node/sentinel"
if collision_output=$(env \
  DEP_MARKER="$TEST_TMP/dependencies-started" \
  VLESS_NODE_DIR="$COLLISION_ROOT/etc/vless-node" \
  VLESS_NODE_BIN_DIR="$COLLISION_ROOT/usr/local/lib/vless-node" \
  VLESS_NODE_UNIT_DIR="$COLLISION_ROOT/etc/systemd/system" \
  VLESS_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    require_supported_host() { :; }
    install_dependencies() { printf "called\n" > "$DEP_MARKER"; }
    install_node
  ' bash "$SCRIPT" 2>&1); then
  fail 'install overwrote an existing vless-node directory'
fi
assert_contains "$collision_output" '配置目录已存在'
assert_eq "$(cat "$COLLISION_ROOT/etc/vless-node/sentinel")" 'keep-existing'
[[ ! -e "$TEST_TMP/dependencies-started" ]] || fail 'collision was detected after dependency installation started'

config_before=$(shasum -a 256 "$INSTALL_ROOT/etc/vless-node/config.json" | awk '{print $1}')
meta_before=$(shasum -a 256 "$INSTALL_ROOT/etc/vless-node/meta.env" | awk '{print $1}')
cat > "$INSTALL_ROOT/usr/local/lib/vless-node/xray" <<'EOF'
#!/usr/bin/env bash
# old-xray
exit 0
EOF
chmod +x "$INSTALL_ROOT/usr/local/lib/vless-node/xray"

if update_output=$(env \
  VLESS_NODE_DIR="$INSTALL_ROOT/etc/vless-node" \
  VLESS_NODE_BIN_DIR="$INSTALL_ROOT/usr/local/lib/vless-node" \
  VLESS_NODE_UNIT_DIR="$INSTALL_ROOT/etc/systemd/system" \
  VLESS_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    require_supported_host() { :; }
    install_dependencies() { :; }
    download_xray_to() {
      cat > "$1" <<"XRAY"
#!/usr/bin/env bash
# new-xray
exit 0
XRAY
      chmod +x "$1"
    }
    systemctl() { :; }
    attempt=0
    wait_for_runtime() { attempt=$((attempt + 1)); ((attempt >= 2)); }
    update_node
  ' bash "$SCRIPT" 2>&1); then
  fail 'update unexpectedly succeeded after new runtime validation failed'
fi
assert_contains "$update_output" '已恢复旧 Xray 和旧服务'
assert_contains "$(cat "$INSTALL_ROOT/usr/local/lib/vless-node/xray")" 'old-xray'
assert_eq "$(shasum -a 256 "$INSTALL_ROOT/etc/vless-node/config.json" | awk '{print $1}')" "$config_before"
assert_eq "$(shasum -a 256 "$INSTALL_ROOT/etc/vless-node/meta.env" | awk '{print $1}')" "$meta_before"

printf 'y\n' | env \
  PATH="$INSTALL_BIN:/usr/bin:/bin" \
  INSTALL_LOG="$INSTALL_LOG" \
  VLESS_NODE_DIR="$INSTALL_ROOT/etc/vless-node" \
  VLESS_NODE_BIN_DIR="$INSTALL_ROOT/usr/local/lib/vless-node" \
  VLESS_NODE_UNIT_DIR="$INSTALL_ROOT/etc/systemd/system" \
  VLESS_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    userdel() { :; }
    uninstall_node
  ' bash "$SCRIPT" >/dev/null

[[ ! -e "$INSTALL_ROOT/etc/vless-node" ]] || fail 'uninstall left its config directory'
[[ ! -e "$INSTALL_ROOT/usr/local/lib/vless-node" ]] || fail 'uninstall left its binary directory'
[[ ! -e "$INSTALL_ROOT/etc/systemd/system/vless-node.service" ]] || fail 'uninstall left its systemd unit'
assert_eq "$(cat "$INSTALL_ROOT/etc/snell-node/sentinel")" 'snell-preserved'
assert_eq "$(cat "$INSTALL_ROOT/etc/surge-node/sentinel")" 'trojan-preserved'

UNRELATED_ROOT="$TEST_TMP/unrelated-root"
mkdir -p "$UNRELATED_ROOT/etc/vless-node" "$UNRELATED_ROOT/etc/systemd/system" "$UNRELATED_ROOT/usr/local/lib/vless-node"
printf 'unrelated\n' > "$UNRELATED_ROOT/etc/vless-node/meta.env"
printf 'unrelated unit\n' > "$UNRELATED_ROOT/etc/systemd/system/vless-node.service"
if unrelated_output=$(printf 'y\n' | env \
  VLESS_NODE_DIR="$UNRELATED_ROOT/etc/vless-node" \
  VLESS_NODE_BIN_DIR="$UNRELATED_ROOT/usr/local/lib/vless-node" \
  VLESS_NODE_UNIT_DIR="$UNRELATED_ROOT/etc/systemd/system" \
  VLESS_NODE_NO_MAIN=1 \
  /bin/bash -c '
    source "$1"
    uninstall_node
  ' bash "$SCRIPT" 2>&1); then
  fail 'uninstall accepted resources without the vless-node ownership marker'
fi
assert_contains "$unrelated_output" '所有权标记'
assert_eq "$(cat "$UNRELATED_ROOT/etc/vless-node/meta.env")" unrelated

printf 'PASS: VLESS host policy, digest checks, network modes, REALITY config, shared Surge rendering, install cleanup, update rollback, and isolated uninstall\n'
