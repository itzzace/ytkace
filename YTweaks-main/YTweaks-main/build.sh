#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEOS="${THEOS:-$ROOT/theos}"
THEOS_COMMIT="67db2ab8d950910161730de77c322658ea3e6b44"
SDK_NAME="iPhoneOS16.5.sdk"

SKIP_SETUP=0
if [[ "${1:-}" == "--skip-setup" ]]; then
  SKIP_SETUP=1
fi

export THEOS

if ! command -v brew >/dev/null 2>&1; then
  echo "Error: Homebrew is required. Install from https://brew.sh" >&2
  exit 1
fi

echo "Installing dependencies..."
brew install make ldid

export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"

setup_theos() {
  if [[ -f "$THEOS/makefiles/common.mk" ]]; then
    echo "Theos already present at $THEOS"
    return
  fi

  echo "Setting up Theos at $THEOS..."
  git clone --recursive --quiet \
    https://github.com/theos/theos.git "$THEOS"
  git -C "$THEOS" checkout --quiet "$THEOS_COMMIT"
}

setup_sdk() {
  if [[ -d "$THEOS/sdks/$SDK_NAME" ]]; then
    echo "SDK already present: $SDK_NAME"
    return
  fi

  echo "Downloading $SDK_NAME..."
  local tmpdir
  tmpdir="$(mktemp -d)"
  (
    git clone --quiet -n --depth=1 --filter=tree:0 https://github.com/theos/sdks/ "$tmpdir/sdks"
    cd "$tmpdir/sdks"
    git sparse-checkout set --no-cone "$SDK_NAME"
    git checkout
    mkdir -p "$THEOS/sdks"
    mv *.sdk "$THEOS/sdks/"
  )
  rm -rf "$tmpdir"
}

setup_header() {
  local name="$1"
  local url="$2"
  local dir="$THEOS/include/$name"

  if [[ -d "$dir" ]]; then
    echo "$name exists. Pulling latest changes..."
    git -C "$dir" pull
  else
    echo "$name does not exist. Cloning repository..."
    mkdir -p "$THEOS/include"
    git clone --quiet --depth=1 "$url" "$dir"
  fi
}

if [[ "$SKIP_SETUP" -eq 0 ]]; then
  setup_theos
  setup_sdk
  setup_header "YouTubeHeader" "https://github.com/PoomSmart/YouTubeHeader.git"
  setup_header "PSHeader" "https://github.com/PoomSmart/PSHeader.git"
fi

cd "$ROOT"
echo "Building YTweaks..."
make clean package DEBUG=0 FINALPACKAGE=1

mv packages/*.deb "$ROOT/YTweaks.deb"

echo "Built: $ROOT/YTweaks.deb"
