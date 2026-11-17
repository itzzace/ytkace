#!/usr/bin/env bash
set -euo pipefail

# Builds the Open in YTKACE Safari extension.
# usage: build-safari-extension.sh out_dir [iphoneos|iphonesimulator]
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: build-safari-extension.sh out_dir [iphoneos|iphonesimulator]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/SafariExtension"
SDK="${2:-iphoneos}"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)/OpenInYTKACE.appex"

case "$SDK" in
  iphoneos) TARGET="arm64-apple-ios15.0"; PLATFORM="iPhoneOS" ;;
  iphonesimulator) TARGET="arm64-apple-ios15.0-simulator"; PLATFORM="iPhoneSimulator" ;;
  *) echo "unknown sdk $SDK" >&2; exit 2 ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$SRC/Resources/." "$OUT/"
cp "$SRC/Info.plist" "$OUT/Info.plist"
plutil -replace CFBundleSupportedPlatforms -json "[\"$PLATFORM\"]" "$OUT/Info.plist"

xcrun -sdk "$SDK" clang -target "$TARGET" -isysroot "$(xcrun -sdk "$SDK" --show-sdk-path)" \
  -fobjc-arc -fapplication-extension -Os \
  -e _NSExtensionMain -framework Foundation \
  -o "$OUT/OpenInYTKACE" "$SRC/SafariWebExtensionHandler.m"

echo "$OUT"
