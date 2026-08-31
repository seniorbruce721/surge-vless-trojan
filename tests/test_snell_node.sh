#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/snell-node.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
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
  env "PATH=$path" "OS_RELEASE_FILE=$fixture" SNELL_NODE_NO_MAIN=1 bash -c '
    source "$1"
    detect_package_manager
  ' bash "$SCRIPT"
}

write_os_release debian debian debian
write_os_release ubuntu ubuntu debian
write_os_release arch arch arch
write_os_release rocky rocky rhel
write_os_release unknown gentoo gentoo

assert_eq "$(detect_with "$TEST_TMP/debian" "$PATH")" apt
assert_eq "$(detect_with "$TEST_TMP/ubuntu" "$PATH")" apt
assert_eq "$(detect_with "$TEST_TMP/arch" "$PATH")" pacman

FAKE_BIN="$TEST_TMP/fake-bin"
mkdir -p "$FAKE_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/dnf"
chmod +x "$FAKE_BIN/dnf"
assert_eq "$(detect_with "$TEST_TMP/rocky" "$FAKE_BIN:$PATH")" dnf
rm "$FAKE_BIN/dnf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/yum"
chmod +x "$FAKE_BIN/yum"
assert_eq "$(detect_with "$TEST_TMP/rocky" "$FAKE_BIN:$PATH")" yum

cat > "$FAKE_BIN/apt-get" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$APT_LOG"
EOF
chmod +x "$FAKE_BIN/apt-get"
APT_LOG="$TEST_TMP/apt.log"
env "PATH=$FAKE_BIN" "OS_RELEASE_FILE=$TEST_TMP/debian" "APT_LOG=$APT_LOG" SNELL_NODE_NO_MAIN=1 /bin/bash -c '
  source "$1"
  install_dependencies
' bash "$SCRIPT" >/dev/null
apt_first=$(sed -n '1p' "$APT_LOG")
apt_second=$(sed -n '2p' "$APT_LOG")
assert_eq "$apt_first" 'update'
assert_eq "$apt_second" 'install -y --no-install-recommends curl unzip openssl iproute2'

if unknown_output=$(detect_with "$TEST_TMP/unknown" "$PATH" 2>&1); then
  fail 'unknown Linux distribution was accepted'
fi
[[ "$unknown_output" == *'未识别的 Linux 发行版'* ]] || fail "unexpected unknown-system error: $unknown_output"

printf 'PASS: Snell version policy, Surge line rendering, and OS package-manager detection\n'
