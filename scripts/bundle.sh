#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]   # ad-hoc signed personal build
#   scripts/bundle.sh debug --fast      # skip dSYM generation
#   scripts/bundle.sh debug --speech    # include bundled speech and MLX

CONFIG="release"
FAST=false
INCLUDE_BUNDLED_SPEECH=false
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        FAST=true ;;
    --speech)      INCLUDE_BUNDLED_SPEECH=true ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RESOURCES="$ROOT/Sources/PalmierPro/Resources"
APP="$ROOT/.build/PalmierPro.app"

BUILD_ARGS=(-c "$CONFIG")
TRAITS=""
if $INCLUDE_BUNDLED_SPEECH; then
  TRAITS="BundledSpeech"
  BUILD_ARGS+=(--traits "$TRAITS")
fi

echo "==> Building ($CONFIG, traits: ${TRAITS:-none})"
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/PalmierPro"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PalmierPro"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"
cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/PalmierPro_PalmierPro.bundle"
if [ -d "$RES_BUNDLE/Fonts" ]; then
  cp -R "$RES_BUNDLE/Fonts" "$APP/Contents/Resources/"
else
  echo "!! missing Fonts/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

# Ensure the shipped Claude Desktop connector is always up to date with mcpb/ sources.
MCPB_SRC="$ROOT/mcpb"
MCPB_CHECKED_IN="$ROOT/Sources/PalmierPro/Resources/MCPB/palmier-pro.mcpb"
MCPB_FRESH="$(mktemp -d)/palmier-pro.mcpb"
(cd "$MCPB_SRC" && zip -q -X -r "$MCPB_FRESH" manifest.json icon.png server/index.js server/package.json)
if ! unzip -p "$MCPB_CHECKED_IN" server/index.js 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" server/index.js) >/dev/null 2>&1 \
  || ! unzip -p "$MCPB_CHECKED_IN" manifest.json 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" manifest.json) >/dev/null 2>&1; then
  echo "==> refreshing checked-in palmier-pro.mcpb from mcpb/ sources"
  cp "$MCPB_FRESH" "$MCPB_CHECKED_IN"
fi
cp "$MCPB_FRESH" "$APP/Contents/Resources/palmier-pro.mcpb"
rm -rf "$(dirname "$MCPB_FRESH")"
if [ -d "$RES_BUNDLE/Images" ]; then
  cp -R "$RES_BUNDLE/Images" "$APP/Contents/Resources/"
fi
# .lproj folders must live at the bundle root for macOS to resolve them.
LOCALIZATION_COUNT=0
for locale_dir in "$RES_BUNDLE"/*.lproj; do
  [ -d "$locale_dir" ] || continue
  for strings_file in Localizable.strings InfoPlist.strings; do
    if [ ! -f "$locale_dir/$strings_file" ]; then
      echo "!! missing $strings_file in $locale_dir" >&2
      exit 1
    fi
  done
  cp -R "$locale_dir" "$APP/Contents/Resources/"
  LOCALIZATION_COUNT=$((LOCALIZATION_COUNT + 1))
done
if [ "$LOCALIZATION_COUNT" -eq 0 ]; then
  echo "!! no compiled localizations in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Models" ]; then
  cp -R "$RES_BUNDLE/Models" "$APP/Contents/Resources/"
else
  echo "!! missing Models/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

# CI kernels: compiled .metallib bytes or runtime-compiled source (see CIKernelLoader).
CIKERNEL_COUNT=0
for kernel in "$RES_BUNDLE"/*.cikernel; do
  [ -f "$kernel" ] || continue
  cp "$kernel" "$APP/Contents/Resources/"
  CIKERNEL_COUNT=$((CIKERNEL_COUNT + 1))
done
if [ "$CIKERNEL_COUNT" -eq 0 ]; then
  echo "!! no .cikernel in SwiftPM resource bundle at $RES_BUNDLE — Metal effects would be missing" >&2
  exit 1
fi

if $INCLUDE_BUNDLED_SPEECH; then
  MLX_METALLIB="$ROOT/.build/$CONFIG/mlx.metallib"
  if [ ! -f "$MLX_METALLIB" ]; then
    echo "==> Building MLX metallib ($CONFIG)"
    BUILD_DIR="$ROOT/.build" "$ROOT/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh" "$CONFIG"
  fi
  if [ ! -f "$MLX_METALLIB" ]; then
    echo "!! missing $MLX_METALLIB — on-device speech features (VAD, speaker ID) would die silently" >&2
    exit 1
  fi
  mkdir -p "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
  cp "$MLX_METALLIB" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
fi

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PalmierPro" 2>/dev/null || true
touch "$APP"

echo "==> Ad-hoc signing app"
codesign --force --deep --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

if ! $FAST; then
  DSYM="$ROOT/.build/PalmierPro.dSYM"
  echo "==> Generating dSYM"
  rm -rf "$DSYM"
  dsymutil "$APP/Contents/MacOS/PalmierPro" -o "$DSYM"
fi

echo "==> Done: $APP (ad-hoc signed)"
echo "Install with: cp -R '$APP' /Applications/"
