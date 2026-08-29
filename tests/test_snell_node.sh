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

printf 'PASS: Snell version policy and Surge line rendering\n'
