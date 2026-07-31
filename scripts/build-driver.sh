#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
BUILD_ROOT="$PROJECT_ROOT/.build/driver"
DRIVER_PATH="$BUILD_ROOT/DualSenseBridgeMic.driver"
CONTENTS_PATH="$DRIVER_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"

mkdir -p "$MACOS_PATH"
cp "$PROJECT_ROOT/Driver/Info.plist" "$CONTENTS_PATH/Info.plist"

xcrun clang \
  -bundle \
  -arch arm64 \
  -arch x86_64 \
  -mmacosx-version-min=13.0 \
  -O2 \
  -Wall \
  -Wextra \
  -framework CoreAudio \
  -framework CoreFoundation \
  "$PROJECT_ROOT/Driver/DualSenseBridgeMic.c" \
  -o "$MACOS_PATH/DualSenseBridgeMic"

chmod 755 "$MACOS_PATH/DualSenseBridgeMic"
plutil -lint "$CONTENTS_PATH/Info.plist"
print -r -- "$DRIVER_PATH"
