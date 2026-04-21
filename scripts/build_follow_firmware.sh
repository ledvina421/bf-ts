#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <betaflight_root> <target-or-config> [extra make vars]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSET_TARGET_DIR="$ASSET_ROOT/target"
BF_ROOT="$(cd "$1" && pwd)"
TARGET_OR_CONFIG="$2"
shift 2

if [ ! -f "$BF_ROOT/Makefile" ] || [ ! -f "$BF_ROOT/src/main/fc/init.c" ]; then
  echo "Invalid Betaflight root: $BF_ROOT" >&2
  exit 1
fi

MAKE_ARGS=()
if [ -d "$BF_ROOT/src/main/target/$TARGET_OR_CONFIG" ]; then
  MAKE_ARGS=("TARGET=$TARGET_OR_CONFIG")
elif [ -f "$BF_ROOT/src/config/configs/$TARGET_OR_CONFIG/config.h" ]; then
  MAKE_ARGS=("CONFIG=$TARGET_OR_CONFIG")
else
  MAKE_ARGS=("TARGET=$TARGET_OR_CONFIG")
fi

TARGET_NAME="$(
  make -s -C "$BF_ROOT" -pn CCACHE= "${MAKE_ARGS[@]}" 2>/dev/null | sed -n 's/^TARGET_NAME := //p' | head -n 1
)"

if [ -z "$TARGET_NAME" ]; then
  TARGET_NAME="$TARGET_OR_CONFIG"
fi

ASSET_ARCHIVE="$ASSET_TARGET_DIR/$TARGET_NAME.a"
if [ ! -f "$ASSET_ARCHIVE" ]; then
  echo "Missing prebuilt archive: $ASSET_ARCHIVE" >&2
  if [ -f "$ASSET_ROOT/private/scripts/build_follow_target_archives.sh" ]; then
    echo "Build it first with: $ASSET_ROOT/private/scripts/build_follow_target_archives.sh $BF_ROOT $TARGET_OR_CONFIG" >&2
  else
    echo "This package only contains the public firmware build workflow." >&2
  fi
  exit 1
fi

(
  cd "$BF_ROOT"
  bash "$SCRIPT_DIR/apply_follow_patch.sh"
)

PATCHED_ARCHIVE="$BF_ROOT/src/main/follow/target/$TARGET_NAME.a"
if [ ! -f "$PATCHED_ARCHIVE" ]; then
  echo "Patched tree is missing target archive: $PATCHED_ARCHIVE" >&2
  exit 1
fi

make -C "$BF_ROOT" CCACHE= "${MAKE_ARGS[@]}" "$@"
