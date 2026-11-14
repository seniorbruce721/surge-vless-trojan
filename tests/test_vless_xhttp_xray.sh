#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/vless-xhttp-node.sh"
XRAY_BIN="${XRAY_TEST_BINARY:-${1:-}}"

[[ -x "$XRAY_BIN" ]] || {
  printf '用法：XRAY_TEST_BINARY=/path/to/official/xray bash %s\n' "$0" >&2
  exit 2
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export VLESS_XHTTP_NO_MAIN=1
# shellcheck disable=SC1090
source "$SCRIPT"

generate_identity "$XRAY_BIN"
for mode in ipv4 ipv6 dual-single dual-split; do
  render_config "$mode" 35443 "$UUID" "$PRIVATE_KEY" "$SHORT_ID" reality.example.com "$XHTTP_PATH" none >"$TMP/plain-$mode.json"
  "$XRAY_BIN" run -test -config "$TMP/plain-$mode.json" >/dev/null
done

generate_vless_encryption "$XRAY_BIN"
for mode in ipv4 ipv6 dual-single dual-split; do
  render_config "$mode" 35444 "$UUID" "$PRIVATE_KEY" "$SHORT_ID" reality.example.com "$XHTTP_PATH" "$VLESS_DECRYPTION" >"$TMP/encryption-$mode.json"
  "$XRAY_BIN" run -test -config "$TMP/encryption-$mode.json" >/dev/null
done

version=$($XRAY_BIN version | head -n1)
printf 'PASS: %s accepted 8 XHTTP + REALITY plain/encryption configs\n' "$version"
