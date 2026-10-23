#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: sideload-repack.sh input.ipa YTKACE.dylib [output.ipa]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
DYLIB="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
OUTPUT="${3:-$PWD/YTKACE_YouTube.ipa}"
OUTPUT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUTPUT")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v unzip >/dev/null 2>&1
command -v zip >/dev/null 2>&1
command -v python3 >/dev/null 2>&1
test -f "$INPUT"
test -f "$DYLIB"

unzip -q "$INPUT" -d "$WORK"
APP="$(find "$WORK/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
test -n "$APP"

case "$(cd "$APP" && pwd)" in
  "$WORK"/*) ;;
  *) echo "invalid app path" >&2; exit 1 ;;
esac

EXECUTABLE="$(
  python3 - "$APP/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    print(plistlib.load(handle)["CFBundleExecutable"])
PY
)"
MAIN="$APP/$EXECUTABLE"

rm -rf "$APP/YTKACE.bundle"
rm -rf "$APP/Extensions/AppMigrationExtension.appex"
rm -rf "$APP/_CodeSignature"
find "$APP" -maxdepth 1 -type f \( -name 'YTK@*' -o -name 'YTK-*' \) -delete
python3 "$ROOT/Tools/sanitize_plist.py" "$APP/Info.plist"

python3 "$ROOT/Tools/macho_inject.py" "$MAIN" \
  --add-load '@rpath/YTKACE.dylib'


mkdir -p "$APP/Frameworks"
cp "$DYLIB" "$APP/Frameworks/YTKACE.dylib"
cp -R "$ROOT/Resources/YTKACE.bundle" "$APP/YTKACE.bundle"


bash "$ROOT/Scripts/sign-bundle.sh" "$APP"

mkdir -p "$(dirname "$OUTPUT")"
ARCHIVE="$WORK/YTKACE_YouTube.ipa"
(
  cd "$WORK"
  zip -qry "$ARCHIVE" Payload
)
mv -f "$ARCHIVE" "$OUTPUT"

echo "$OUTPUT"
