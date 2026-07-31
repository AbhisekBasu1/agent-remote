#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h:h}
OUTPUT_PATH=${1:-"$PROJECT_ROOT/.build/audio-lab/libsonic.dylib"}
BUILD_ARCH=${AUDIO_LAB_BUILD_ARCH:-$(uname -m)}

case "$BUILD_ARCH" in
  arm64|x86_64) ;;
  *)
    print -u2 -- "error: AUDIO_LAB_BUILD_ARCH must be arm64 or x86_64"
    exit 2
    ;;
esac

mkdir -p "${OUTPUT_PATH:h}"
xcrun clang \
  -dynamiclib \
  -arch "$BUILD_ARCH" \
  -mmacosx-version-min=13.0 \
  -O2 \
  -Wall \
  -Wextra \
  -Wno-unused-parameter \
  -I "$PROJECT_ROOT/Sources/CSonic/include" \
  "$PROJECT_ROOT/Sources/CSonic/sonic.c" \
  -o "$OUTPUT_PATH"

/usr/bin/lipo "$OUTPUT_PATH" -verify_arch "$BUILD_ARCH"
print -r -- "$OUTPUT_PATH"
