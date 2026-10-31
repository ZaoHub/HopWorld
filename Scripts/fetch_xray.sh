#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/HopWorld/Resources"
SUPPORT="$HOME/Library/Application Support/HopWorld"
VERSION="${XRAY_VERSION:-26.10.21}"
ARCH="$(uname -m)"

case "$ARCH" in
  arm64|aarch64) XRAY_ARCH="arm64-v8a" ;;
  x86_64) XRAY_ARCH="64" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

ZIP_NAME="Xray-macos-${XRAY_ARCH}.zip"
URL="https://github.com/XTLS/Xray-core/releases/download/v${VERSION}/${ZIP_NAME}"
TMP="$(mktemp -d)"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "Downloading $URL"
curl -L --fail --retry 3 -o "$TMP/$ZIP_NAME" "$URL"
unzip -o "$TMP/$ZIP_NAME" -d "$TMP/out"

mkdir -p "$DEST" "$SUPPORT"

# Prefer binary named xray; some archives may nest it.
XRAY_BIN="$(find "$TMP/out" -type f -name xray | head -n 1)"
if [[ -z "$XRAY_BIN" ]]; then
  echo "xray binary not found in archive"
  exit 1
fi

cp "$XRAY_BIN" "$DEST/xray"
chmod +x "$DEST/xray"
cp "$XRAY_BIN" "$SUPPORT/xray"
chmod +x "$SUPPORT/xray"

# Clear quarantine so Gatekeeper does not block Process.run
xattr -dr com.apple.quarantine "$DEST/xray" 2>/dev/null || true
xattr -dr com.apple.quarantine "$SUPPORT/xray" 2>/dev/null || true

if [[ -f "$TMP/out/geoip.dat" ]]; then
  cp "$TMP/out/geoip.dat" "$DEST/geoip.dat"
  cp "$TMP/out/geoip.dat" "$SUPPORT/geoip.dat"
fi
if [[ -f "$TMP/out/geosite.dat" ]]; then
  cp "$TMP/out/geosite.dat" "$DEST/geosite.dat"
  cp "$TMP/out/geosite.dat" "$SUPPORT/geosite.dat"
fi

echo "Installed xray to:"
echo "  $DEST/xray"
echo "  $SUPPORT/xray"
"$SUPPORT/xray" version || true
