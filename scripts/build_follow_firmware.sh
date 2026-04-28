#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local exit_code="$1"
  local line_no="$2"
  echo "Error: build_follow_firmware.sh failed at line ${line_no}: ${BASH_COMMAND}" >&2
  echo "Error: firmware build did not complete." >&2
  exit "$exit_code"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
}

print_selector_suggestions() {
  local input="$1"
  local hint="${input##*_}"
  local shown=0
  local path=""
  local name=""

  shopt -s nullglob

  for path in "$BF_ROOT"/src/config/configs/*/config.h; do
    name="${path%/config.h}"
    name="${name##*/}"
    case "$name" in
      *"$input"*|*"$hint"*)
        echo "Hint: available config: $name" >&2
        shown=1
        ;;
    esac
  done

  for path in "$BF_ROOT"/src/main/target/*; do
    [ -d "$path" ] || continue
    name="${path##*/}"
    case "$name" in
      *"$input"*|*"$hint"*)
        echo "Hint: available target: $name" >&2
        shown=1
        ;;
    esac
  done

  shopt -u nullglob

  if [ "$shown" -eq 0 ]; then
    echo "Hint: no similar target or config name was found in this Betaflight tree." >&2
  fi
}

summarize_make_failure() {
  local make_output="$1"
  local summary=""

  summary="$(
    printf '%s\n' "$make_output" \
      | sed -n \
        -e '/^Makefile:[0-9][0-9]*: \*\*\*/p' \
        -e '/^mk\/[^:]*:[0-9][0-9]*: \*\*\*/p' \
        -e '/^fatal:/p' \
        -e '/^warning:/p' \
        -e '/^Error:/p' \
        -e '/not found/p' \
      | head -n 20
  )"

  if [ -n "$summary" ]; then
    echo "$summary" >&2
    return
  fi

  printf '%s\n' "$make_output" | tail -n 40 >&2
}

trap 'on_error $? $LINENO' ERR

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <betaflight_root> <target-or-config> [--skip-patch|--apply-patch] [--pid-file <path>] [extra make vars]" >&2
  echo "Example extra make vars: FOLLOW_WORK_SERIAL_PORT=SERIAL_PORT_UART4 FOLLOW_SIM_SERIAL_PORT=SERIAL_PORT_USART3" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSET_TARGET_DIR="$ASSET_ROOT/target"
BF_ROOT="$(cd "$1" && pwd)"
TARGET_OR_CONFIG="$2"
shift 2
APPLY_PATCH="yes"
PID_FILE=""
EXTRA_MAKE_VARS=()

require_command make
require_command sed
require_command install

install_pid_defaults_header() {
  local dst_header="$1"
  local src_header="$ASSET_ROOT/include/follow/follow_pid_defaults.h"

  mkdir -p "$(dirname "$dst_header")"
  if ! install -m 0644 "$src_header" "$dst_header"; then
    echo "Error: failed to install PID defaults header to $dst_header" >&2
    exit 1
  fi
}

generate_pid_defaults_header() {
  local pid_file="$1"
  local dst_header="$2"

  python3 - "$pid_file" "$dst_header" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

if not src.is_file():
    raise SystemExit(f"Error: PID defaults file not found: {src}")

lines = []
for raw_line in src.read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    values = [item.strip() for item in line.split(",")]
    if len(values) != 28:
        raise SystemExit(
            f"Error: each PID line must contain 28 comma-separated floats, got {len(values)} in: {raw_line}"
        )

    parsed = []
    for value in values:
        try:
            number = float(value)
        except ValueError as exc:
            raise SystemExit(f"Error: invalid float value '{value}' in PID file") from exc
        parsed.append(format(number, ".9g"))

    lines.append(parsed)

if len(lines) != 6:
    raise SystemExit(f"Error: PID file must contain exactly 6 data lines, got {len(lines)}")

def emit_macro(index: int, values: list[str]) -> str:
    groups = [", ".join(value for value in values[offset:offset + 7]) for offset in range(0, 28, 7)]
    body = ", \\\n        ".join(groups)
    return (
        f"#define FOLLOW_PID_PROFILE{index}_DEFAULTS \\\n"
        "    { \\\n"
        f"        {body} \\\n"
        "    }\n"
    )

content = "#pragma once\n\n" + "\n".join(emit_macro(i, values) for i, values in enumerate(lines, start=1))
dst.write_text(content)
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-patch)
      APPLY_PATCH="no"
      shift
      ;;
    --apply-patch)
      APPLY_PATCH="yes"
      shift
      ;;
    --pid-file)
      if [ "$#" -lt 2 ]; then
        echo "Error: --pid-file requires a file path" >&2
        exit 1
      fi
      PID_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
      shift 2
      ;;
    *)
      EXTRA_MAKE_VARS+=("$1")
      shift
      ;;
  esac
done

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
  echo "Error: '$TARGET_OR_CONFIG' is neither a valid target nor a valid config in $BF_ROOT" >&2
  print_selector_suggestions "$TARGET_OR_CONFIG"
  exit 1
fi

if ! MAKE_DB="$(make -s -C "$BF_ROOT" -pn CCACHE= "${MAKE_ARGS[@]}" "${EXTRA_MAKE_VARS[@]}" 2>&1)"; then
  echo "Error: failed to resolve build variables for $TARGET_OR_CONFIG" >&2
  summarize_make_failure "$MAKE_DB"
  exit 1
fi

TARGET_NAME="$(
  printf '%s\n' "$MAKE_DB" | sed -n 's/^TARGET_NAME := //p' | head -n 1
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

install_target_archive() {
  local dst_dir="$BF_ROOT/src/main/follow/target"
  local dst_archive="$dst_dir/$TARGET_NAME.a"
  mkdir -p "$dst_dir"
  if ! install -m 0644 "$ASSET_ARCHIVE" "$dst_archive"; then
    echo "Error: failed to install target archive to $dst_archive" >&2
    exit 1
  fi
}

if [ "$APPLY_PATCH" = "yes" ]; then
  echo "Applying patch before firmware build"
  (
    cd "$BF_ROOT"
    bash "$SCRIPT_DIR/apply_follow_patch.sh"
  )
else
  echo "Skipping patch application as requested"
  if [ ! -f "$BF_ROOT/src/main/follow/follow_bundle.c" ]; then
    echo "Error: --skip-patch was requested, but the Betaflight tree does not appear to be patched." >&2
    echo "Error: missing file: $BF_ROOT/src/main/follow/follow_bundle.c" >&2
    exit 1
  fi
fi

install_target_archive

PID_HEADER="$BF_ROOT/src/main/follow/follow_pid_defaults.h"
install_pid_defaults_header "$PID_HEADER"

if [ -n "$PID_FILE" ]; then
  require_command python3
  generate_pid_defaults_header "$PID_FILE" "$PID_HEADER"
  echo "Applied PID defaults from: $PID_FILE"
fi

PATCHED_ARCHIVE="$BF_ROOT/src/main/follow/target/$TARGET_NAME.a"
if [ ! -f "$PATCHED_ARCHIVE" ]; then
  echo "Patched tree is missing target archive: $PATCHED_ARCHIVE" >&2
  exit 1
fi

echo "Building firmware for input: $TARGET_OR_CONFIG"
echo "Resolved TARGET_NAME: $TARGET_NAME"
echo "Patch step: $APPLY_PATCH"

if ! make -C "$BF_ROOT" CCACHE= "${MAKE_ARGS[@]}" "${EXTRA_MAKE_VARS[@]}"; then
  echo "Error: Betaflight firmware build failed for $TARGET_OR_CONFIG" >&2
  exit 1
fi
