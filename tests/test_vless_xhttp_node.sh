#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/vless-xhttp-node.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "expected output not to contain [$2], got [$1]"; }

[[ -f "$SCRIPT" ]] || fail 'vless-xhttp-node.sh is missing'

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export VLESS_XHTTP_TEST_MODE=1

profile_values() {
  VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
    source "$1"
    select_profile "$2"
    printf "%s|%s|%s|%s|%s" "$PROFILE" "$UNIT" "$DIR" "$BIN_DIR" "$DEFAULT_PORT"
  ' bash "$SCRIPT" "$1"
}

assert_eq "$(profile_values plain)" 'plain|vless-xhttp-plain.service|/etc/vless-xhttp-node/plain|/usr/local/lib/vless-xhttp-node/plain|24443'
assert_eq "$(profile_values encryption)" 'encryption|vless-xhttp-encryption.service|/etc/vless-xhttp-node/encryption|/usr/local/lib/vless-xhttp-node/encryption|24444'
if profile_values arbitrary >/dev/null 2>&1; then
  fail 'arbitrary profile was accepted'
fi

write_os_release() {
  local file="$1" id="$2" version="$3" pretty="$4"
  printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s"\n' "$id" "$version" "$pretty" >"$file"
}
for fixture in debian-12 debian-13 ubuntu-2404 ubuntu-2604; do
  case "$fixture" in
    debian-12) write_os_release "$TEST_TMP/$fixture" debian 12 'Debian 12' ;;
    debian-13) write_os_release "$TEST_TMP/$fixture" debian 13 'Debian 13' ;;
    ubuntu-2404) write_os_release "$TEST_TMP/$fixture" ubuntu 24.04 'Ubuntu 24.04' ;;
    ubuntu-2604) write_os_release "$TEST_TMP/$fixture" ubuntu 26.04 'Ubuntu 26.04' ;;
  esac
  OS_RELEASE_FILE="$TEST_TMP/$fixture" VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
    source "$1"
    uname() { case "$1" in -s) printf "Linux\n" ;; -m) printf "x86_64\n" ;; esac; }
    command() { [[ "$1" == -v && "$2" == systemctl ]]; }
    require_supported_host
  ' bash "$SCRIPT"
done
write_os_release "$TEST_TMP/ubuntu-2204" ubuntu 22.04 'Ubuntu 22.04'
if unsupported=$(OS_RELEASE_FILE="$TEST_TMP/ubuntu-2204" VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
  source "$1"
  uname() { case "$1" in -s) printf "Linux\n" ;; -m) printf "x86_64\n" ;; esac; }
  command() { [[ "$1" == -v && "$2" == systemctl ]]; }
  require_supported_host
' bash "$SCRIPT" 2>&1); then
  fail 'unsupported Ubuntu 22.04 host was accepted'
fi
assert_contains "$unsupported" '仅支持 Debian 12/13 和 Ubuntu 24.04/26.04'

release_pair=$(VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
  source "$1"
  curl() { printf '\''{"draft":false,"prerelease":false,"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://github.com/XTLS/Xray-core/releases/download/v1/Xray-linux-64.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'\''; }
  release_asset XTLS/Xray-core Xray-linux-64.zip
' bash "$SCRIPT")
assert_eq "$release_pair" 'https://github.com/XTLS/Xray-core/releases/download/v1/Xray-linux-64.zip|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
if prerelease=$(VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
  source "$1"
  curl() { printf '\''{"draft":false,"prerelease":true,"assets":[{"name":"Xray-linux-64.zip","browser_download_url":"https://example.invalid/xray.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'\''; }
  release_asset XTLS/Xray-core Xray-linux-64.zip
' bash "$SCRIPT" 2>&1); then
  fail 'Xray prerelease was accepted as stable'
fi

CONFIG_DIR="$TEST_TMP/configs"
mkdir -p "$CONFIG_DIR"
for profile in plain encryption; do
  decryption=none
  [[ "$profile" == encryption ]] && decryption='mlkem768x25519plus.native.600s.100-111-1111.test-server-secret'
  VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
    source "$1"
    render_config dual-split 24443 test-uuid test-private 0123456789abcdef \
      reality.example.com /test-path "$2"
  ' bash "$SCRIPT" "$decryption" > "$CONFIG_DIR/$profile.json"
done

python3 - "$CONFIG_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for profile in ("plain", "encryption"):
    config = json.loads((root / f"{profile}.json").read_text())
    assert [item["listen"] for item in config["inbounds"]] == ["0.0.0.0", "::"]
    for inbound in config["inbounds"]:
        assert inbound["protocol"] == "vless"
        assert inbound["settings"]["clients"] == [{"id": "test-uuid", "flow": ""}]
        stream = inbound["streamSettings"]
        assert stream["network"] == "xhttp"
        assert stream["xhttpSettings"] == {"path": "/test-path", "mode": "stream-one"}
        assert stream["security"] == "reality"
        assert stream["realitySettings"]["target"] == "reality.example.com:443"
        assert stream["realitySettings"]["serverNames"] == ["reality.example.com"]
    expected = "none" if profile == "plain" else "mlkem768x25519plus.native.600s.100-111-1111.test-server-secret"
    assert all(i["settings"]["decryption"] == expected for i in config["inbounds"])
PY

enc_output=$(VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
  source "$1"
  fake_xray() {
    [[ "$1" == vlessenc ]]
    cat <<'\''OUTPUT'\''
Authentication: X25519, not Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.x25519-server"
"encryption": "mlkem768x25519plus.native.0rtt.x25519-client"

Authentication: ML-KEM-768, Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.mlkem-server"
"encryption": "mlkem768x25519plus.native.0rtt.mlkem-client"
OUTPUT
  }
  generate_vless_encryption fake_xray
  printf "%s|%s" "$VLESS_DECRYPTION" "$VLESS_ENCRYPTION"
' bash "$SCRIPT")
assert_eq "$enc_output" 'mlkem768x25519plus.native.600s.mlkem-server|mlkem768x25519plus.native.0rtt.mlkem-client'

if invalid_enc=$(VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
  source "$1"
  fake_xray() { printf '\''"decryption": "none"\n"encryption": "guessed"\n'\''; }
  generate_vless_encryption fake_xray
' bash "$SCRIPT" 2>&1); then
  fail 'invalid vlessenc output was accepted'
fi
assert_contains "$invalid_enc" 'vlessenc'

VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
  source "$1"
  fake_xray() { [[ "$1" == tls && "$2" == ping ]]; }
  curl() { printf 2; }
  validate_sni_target fake_xray reality.example.com
' bash "$SCRIPT"
if bad_h2=$(VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
  source "$1"
  fake_xray() { [[ "$1" == tls && "$2" == ping ]]; }
  curl() { printf "1.1"; }
  validate_sni_target fake_xray reality.example.com
' bash "$SCRIPT" 2>&1); then
  fail 'SNI target without HTTP/2 was accepted'
fi
assert_contains "$bad_h2" '未协商 HTTP/2'

PORT_BIN="$TEST_TMP/port-bin"
mkdir -p "$PORT_BIN"
cat > "$PORT_BIN/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 4096 0.0.0.0:24443 0.0.0.0:*\n'
EOF
chmod +x "$PORT_BIN/ss"
if occupied=$(PATH="$PORT_BIN:/usr/bin:/bin" VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
  source "$1"
  port_is_free 24443
' bash "$SCRIPT" 2>&1); then
  fail 'occupied port was accepted'
fi
assert_contains "$occupied" '24443'

connections=$(VLESS_XHTTP_NO_MAIN=1 /bin/bash -c '
  source "$1"
  render_connection_info encryption 203.0.113.8 2001:db8::8 node.example.com dual \
    24444 test-uuid test-public 0123456789abcdef reality.example.com /test-path \
    mlkem768x25519plus.native.600s.100-111-1111.client
' bash "$SCRIPT")
assert_contains "$connections" '模式：VLESS + XHTTP + REALITY + Encryption'
assert_contains "$connections" 'XHTTP Mode：stream-one'
assert_contains "$connections" 'HTTP：优先 HTTP/2'
assert_contains "$connections" '服务器 IPv4：203.0.113.8'
assert_contains "$connections" '服务器 IPv6：2001:db8::8'
assert_contains "$connections" 'VLESS Encryption：mlkem768x25519plus'
assert_contains "$connections" 'Surge 6.100.0 (4026)'
assert_contains "$connections" '待客户端导入验证'
assert_not_contains "$connections" 'test-private'

INSTALL_ROOT="$TEST_TMP/install-root"
MOCK_BIN="$TEST_TMP/mock-bin"
CALL_LOG="$TEST_TMP/calls.log"
mkdir -p "$INSTALL_ROOT/etc/systemd/system" "$INSTALL_ROOT/etc/snell-node" \
  "$INSTALL_ROOT/etc/vless-node" "$INSTALL_ROOT/etc/surge-node" "$INSTALL_ROOT/usr/local/lib" "$MOCK_BIN"
printf 'keep-snell\n' > "$INSTALL_ROOT/etc/snell-node/sentinel"
printf 'keep-vless\n' > "$INSTALL_ROOT/etc/vless-node/sentinel"
printf 'keep-trojan\n' > "$INSTALL_ROOT/etc/surge-node/sentinel"

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl:%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  is-active|is-enabled) exit 0 ;;
  show) printf '0\n' ;;
esac
exit 0
EOF
cat > "$MOCK_BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$MOCK_BIN/nc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$MOCK_BIN/getent" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$MOCK_BIN/ufw" <<'EOF'
#!/usr/bin/env bash
printf 'ufw:%s\n' "$*" >> "$CALL_LOG"
printf 'Status: inactive\n'
EOF
cat > "$MOCK_BIN/userdel" <<'EOF'
#!/usr/bin/env bash
printf 'userdel:%s\n' "$*" >> "$CALL_LOG"
EOF
chmod +x "$MOCK_BIN"/*

install_profile() {
  local profile="$1"
  local command_bin="${2:-$MOCK_BIN}"
  env PATH="$command_bin:/usr/bin:/bin" CALL_LOG="$CALL_LOG" \
    VLESS_XHTTP_BASE_DIR="$INSTALL_ROOT/etc/vless-xhttp-node" \
    VLESS_XHTTP_BASE_BIN_DIR="$INSTALL_ROOT/usr/local/lib/vless-xhttp-node" \
    VLESS_XHTTP_UNIT_DIR="$INSTALL_ROOT/etc/systemd/system" \
    VLESS_XHTTP_NO_MAIN=1 VLESS_XHTTP_TEST_MODE=1 \
    /bin/bash -c '
      source "$1"
      select_profile "$2"
      require_supported_host() { :; }
      install_dependencies() { :; }
      interactive_terminal() { return 0; }
      ensure_service_user() { :; }
      chown() { :; }
      collect_network_state() {
        IPV4_PUBLIC=yes; IPV6_PUBLIC=yes
        PUBLIC_IPV4=203.0.113.8; PUBLIC_IPV6=2001:db8::8
        IPV4_REASON=ok; IPV6_REASON=ok
      }
      ask() {
        case "$1" in
          *"端口"*) [[ "$PROFILE" == plain ]] && printf 24443 || printf 24444 ;;
          *"SNI"*) printf reality.example.com ;;
          *"连接域名"*) printf "" ;;
        esac
      }
      download_xray_to() {
        cat > "$1" <<"XRAY"
#!/usr/bin/env bash
case "$1" in
  uuid) printf "2cae91b3-f85c-433b-88ee-a002b9ed6d61\n" ;;
  x25519) printf "Private key: test-private\nPublic key: test-public\n" ;;
  vlessenc) cat <<"OUTPUT"
Authentication: X25519, not Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.x-server"
"encryption": "mlkem768x25519plus.native.0rtt.x-client"
Authentication: ML-KEM-768, Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.mlkem-server"
"encryption": "mlkem768x25519plus.native.0rtt.mlkem-client"
OUTPUT
    ;;
  *) exit 0 ;;
esac
XRAY
        chmod +x "$1"
      }
      validate_sni_target() { :; }
      probe_candidate_mode() { [[ "$1" == dual-split ]]; }
      install_node
    ' bash "$SCRIPT" "$profile"
}

plain_output=$(install_profile plain)
encryption_output=$(install_profile encryption)
assert_contains "$plain_output" '模式：VLESS + XHTTP + REALITY'
assert_contains "$encryption_output" 'VLESS Encryption：mlkem768x25519plus'
[[ -f "$INSTALL_ROOT/etc/systemd/system/vless-xhttp-plain.service" ]] || fail 'plain unit was not installed'
[[ -f "$INSTALL_ROOT/etc/systemd/system/vless-xhttp-encryption.service" ]] || fail 'encryption unit was not installed'
[[ -f "$INSTALL_ROOT/etc/vless-xhttp-node/plain/config.json" ]] || fail 'plain config was not installed'
[[ -f "$INSTALL_ROOT/etc/vless-xhttp-node/encryption/config.json" ]] || fail 'encryption config was not installed'
assert_eq "$(stat -f '%Lp' "$INSTALL_ROOT/etc/vless-xhttp-node")" 755
assert_eq "$(stat -f '%Lp' "$INSTALL_ROOT/etc/vless-xhttp-node/plain")" 750
assert_eq "$(stat -f '%Lp' "$INSTALL_ROOT/etc/vless-xhttp-node/plain/config.json")" 640
assert_eq "$(stat -f '%Lp' "$INSTALL_ROOT/etc/vless-xhttp-node/plain/meta.env")" 600
assert_eq "$(stat -f '%Lp' "$INSTALL_ROOT/etc/vless-xhttp-node/plain/connections.txt")" 600
assert_contains "$(cat "$INSTALL_ROOT/etc/vless-xhttp-node/encryption/meta.env")" 'PROFILE=encryption'
assert_contains "$(cat "$INSTALL_ROOT/etc/vless-xhttp-node/encryption/meta.env")" 'VLESS_ENCRYPTION=mlkem768x25519plus.'

env PATH="$MOCK_BIN:/usr/bin:/bin" CALL_LOG="$CALL_LOG" \
  VLESS_XHTTP_BASE_DIR="$INSTALL_ROOT/etc/vless-xhttp-node" \
  VLESS_XHTTP_BASE_BIN_DIR="$INSTALL_ROOT/usr/local/lib/vless-xhttp-node" \
  VLESS_XHTTP_UNIT_DIR="$INSTALL_ROOT/etc/systemd/system" \
  VLESS_XHTTP_NO_MAIN=1 VLESS_XHTTP_TEST_MODE=1 \
  /bin/bash -c 'source "$1"; select_profile plain; printf "y\n" | uninstall_node' bash "$SCRIPT" >/dev/null

[[ ! -e "$INSTALL_ROOT/etc/vless-xhttp-node/plain" ]] || fail 'plain uninstall left its config directory'
[[ ! -e "$INSTALL_ROOT/etc/systemd/system/vless-xhttp-plain.service" ]] || fail 'plain uninstall left its unit'
[[ -f "$INSTALL_ROOT/etc/vless-xhttp-node/encryption/config.json" ]] || fail 'plain uninstall removed encryption config'
[[ -f "$INSTALL_ROOT/etc/systemd/system/vless-xhttp-encryption.service" ]] || fail 'plain uninstall removed encryption unit'
assert_eq "$(cat "$INSTALL_ROOT/etc/snell-node/sentinel")" 'keep-snell'
assert_eq "$(cat "$INSTALL_ROOT/etc/vless-node/sentinel")" 'keep-vless'
assert_eq "$(cat "$INSTALL_ROOT/etc/surge-node/sentinel")" 'keep-trojan'
assert_not_contains "$(cat "$CALL_LOG")" 'ufw:allow'
assert_not_contains "$(cat "$CALL_LOG")" 'ufw:delete'
assert_not_contains "$(cat "$CALL_LOG")" 'ufw:reset'
assert_not_contains "$(cat "$CALL_LOG")" 'systemctl:stop snell-node'
assert_not_contains "$(cat "$CALL_LOG")" 'systemctl:restart vless-node'

FAIL_BIN="$TEST_TMP/fail-bin"
mkdir -p "$FAIL_BIN"
for tool in ss nc getent ufw userdel; do ln -s "$MOCK_BIN/$tool" "$FAIL_BIN/$tool"; done
cat > "$FAIL_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl:%s\n' "$*" >> "$CALL_LOG"
if [[ "$1" == enable ]]; then exit 1; fi
case "$1" in show) printf '0\n' ;; esac
exit 0
EOF
chmod +x "$FAIL_BIN/systemctl"
if failed_install=$(install_profile plain "$FAIL_BIN" 2>&1); then
  fail 'plain install unexpectedly succeeded when systemd enable failed'
fi
assert_contains "$failed_install" '服务启动或本地监听验证失败'
[[ ! -e "$INSTALL_ROOT/etc/vless-xhttp-node/plain" ]] || fail 'failed plain install left its config directory'
[[ ! -e "$INSTALL_ROOT/etc/systemd/system/vless-xhttp-plain.service" ]] || fail 'failed plain install left its unit'
[[ -f "$INSTALL_ROOT/etc/vless-xhttp-node/encryption/config.json" ]] || fail 'failed plain rollback removed encryption config'

assert_not_contains "$(cat "$SCRIPT")" 'systemctl restart snell-node'
assert_not_contains "$(cat "$SCRIPT")" 'systemctl stop snell-node'
assert_not_contains "$(cat "$SCRIPT")" 'systemctl restart vless-node'
assert_not_contains "$(cat "$SCRIPT")" 'ufw allow'
assert_not_contains "$(cat "$SCRIPT")" 'ufw reset'
assert_not_contains "$(cat "$SCRIPT")" 'nft flush'
assert_not_contains "$(cat "$SCRIPT")" 'iptables -F'

printf 'PASS: XHTTP profiles, official encryption parsing, config generation, and isolation boundaries\n'
