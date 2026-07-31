#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
SCRATCH_PATH="$PROJECT_ROOT/.build"
MODULE_CACHE="$SCRATCH_PATH/ModuleCache"
PACKAGE_ROOT="$SCRATCH_PATH/package"
APP_PATH="$PACKAGE_ROOT/Agent Remote.app"
DIST_ROOT="$PROJECT_ROOT/dist"
OUTPUT_APP_PATH="$DIST_ROOT/Agent Remote.app"
CONTENTS_PATH="$APP_PATH/Contents"
FRAMEWORKS_PATH="$CONTENTS_PATH/Frameworks"
PLUGINS_PATH="$CONTENTS_PATH/PlugIns"
BUNDLED_DRIVER_PATH="$PLUGINS_PATH/DualSenseBridgeMic.driver"
SIGNING_KEYCHAIN="$PROJECT_ROOT/.local-signing/DualSenseBridge.keychain-db"
SIGNING_KEYCHAIN_PASSWORD="DualSenseBridgeLocalKeychain2026"
SIGNING_IDENTITY_NAME="DualSense Bridge Local Code Signing"
BUILD_ARCH="${AGENT_REMOTE_BUILD_ARCH:-$(uname -m)}"

case "$BUILD_ARCH" in
  arm64|x86_64) ;;
  *)
    print -u2 -- "error: AGENT_REMOTE_BUILD_ARCH must be arm64 or x86_64"
    exit 2
    ;;
esac

/bin/rm -rf -- "$APP_PATH"
mkdir -p "$MODULE_CACHE" "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources" "$FRAMEWORKS_PATH" "$PLUGINS_PATH"

"$SCRIPT_DIR/build-driver.sh"
ditto "$PROJECT_ROOT/.build/driver/DualSenseBridgeMic.driver" "$BUNDLED_DRIVER_PATH"
cp "$PROJECT_ROOT/Driver/LICENSE-APPLE.txt" "$CONTENTS_PATH/Resources/AudioDriver-APPLE-LICENSE.txt"
cp "$PROJECT_ROOT/LICENSE" "$CONTENTS_PATH/Resources/AgentRemote-LICENSE.txt"
cp "$PROJECT_ROOT/PRIVACY.md" "$CONTENTS_PATH/Resources/PRIVACY.txt"
cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS_PATH/Resources/THIRD-PARTY-NOTICES.txt"
cp "$PROJECT_ROOT/ThirdParty/Opus/LICENSE" "$CONTENTS_PATH/Resources/Opus-LICENSE.txt"
cp "$PROJECT_ROOT/ThirdParty/Sonic/LICENSE" "$CONTENTS_PATH/Resources/Sonic-APACHE-LICENSE.txt"
cp "$PROJECT_ROOT/ThirdParty/Yabai/LICENSE" "$CONTENTS_PATH/Resources/Yabai-MIT-LICENSE.txt"
cp "$SCRIPT_DIR/install-driver.sh" "$CONTENTS_PATH/Resources/install-driver.sh"
chmod 755 "$CONTENTS_PATH/Resources/install-driver.sh"
cp "$SCRIPT_DIR/uninstall-driver.sh" "$CONTENTS_PATH/Resources/uninstall-driver.sh"
chmod 755 "$CONTENTS_PATH/Resources/uninstall-driver.sh"
cp "$PROJECT_ROOT/App/agent-remote-event" "$CONTENTS_PATH/Resources/agent-remote-event"
chmod 755 "$CONTENTS_PATH/Resources/agent-remote-event"
cp "$PROJECT_ROOT/App/Resources/AgentRemoteMenuBarIcon.png" \
  "$CONTENTS_PATH/Resources/AgentRemoteMenuBarIcon.png"

export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

typeset -a SWIFT_BUILD_ARGS
SWIFT_BUILD_ARGS=(
  --disable-sandbox
  --package-path "$PROJECT_ROOT"
  --scratch-path "$SCRATCH_PATH"
  -c release
  --arch "$BUILD_ARCH"
  -Xswiftc -module-cache-path
  -Xswiftc "$MODULE_CACHE"
)
SWIFT_BIN_PATH=$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)
swift build "${SWIFT_BUILD_ARGS[@]}"

cp "$SWIFT_BIN_PATH/DualSenseBridge" "$CONTENTS_PATH/MacOS/DualSenseBridge"
cp "$PROJECT_ROOT/App/Info.plist" "$CONTENTS_PATH/Info.plist"
chmod +x "$CONTENTS_PATH/MacOS/DualSenseBridge"
/usr/bin/lipo "$CONTENTS_PATH/MacOS/DualSenseBridge" -verify_arch "$BUILD_ARCH"

OPUS_PREFIX="${OPUS_PREFIX:-/opt/homebrew/opt/opus}"
if [[ ! -f "$OPUS_PREFIX/lib/libopus.0.dylib" ]]; then
  OPUS_PREFIX="/usr/local/opt/opus"
fi
if [[ ! -f "$OPUS_PREFIX/lib/libopus.0.dylib" ]]; then
  print -u2 -- "error: libopus is required to package Bluetooth microphone support"
  print -u2 -- "install it with: brew install opus"
  exit 1
fi
if ! /usr/bin/lipo "$OPUS_PREFIX/lib/libopus.0.dylib" -verify_arch "$BUILD_ARCH"; then
  print -u2 -- "error: $OPUS_PREFIX/lib/libopus.0.dylib does not contain $BUILD_ARCH"
  print -u2 -- "set OPUS_PREFIX to an Opus installation for the requested architecture"
  exit 1
fi
cp -L "$OPUS_PREFIX/lib/libopus.0.dylib" "$FRAMEWORKS_PATH/libopus.0.dylib"
chmod 755 "$FRAMEWORKS_PATH/libopus.0.dylib"
OPUS_CELLAR_PATH=$(cd "$OPUS_PREFIX" && pwd -P)
OPUS_VERSION=${OPUS_CELLAR_PATH:t}
SWIFT_VERSION_OUTPUT=$(swift --version 2>/dev/null)
SWIFT_VERSION_LINE=${SWIFT_VERSION_OUTPUT%%$'\n'*}
{
  print -r -- "Agent Remote build components"
  print -r -- "App version: $(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$CONTENTS_PATH/Info.plist")"
  print -r -- "Architecture: $BUILD_ARCH"
  print -r -- "Opus package version: $OPUS_VERSION"
  print -r -- "$SWIFT_VERSION_LINE"
} > "$CONTENTS_PATH/Resources/BUILD-COMPONENTS.txt"

SIGNING_IDENTITY_HASH=""
if [[ -f "$SIGNING_KEYCHAIN" ]]; then
  security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
  SIGNING_IDENTITY_HASH=$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" \
    | awk -v identity="$SIGNING_IDENTITY_NAME" 'index($0, identity) { print $2; exit }')
fi

if [[ -n "$SIGNING_IDENTITY_HASH" ]]; then
  typeset -a ORIGINAL_KEYCHAINS
  typeset -a SIGNING_SEARCH_KEYCHAINS
  ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user \
    | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')}")
  SIGNING_SEARCH_KEYCHAINS=("$SIGNING_KEYCHAIN")
  for keychain in "${ORIGINAL_KEYCHAINS[@]}"; do
    if [[ "$keychain" != "$SIGNING_KEYCHAIN" ]]; then
      SIGNING_SEARCH_KEYCHAINS+=("$keychain")
    fi
  done

  KEYCHAIN_SEARCH_LIST_CHANGED=0
  restore_keychain_search_list() {
    if (( KEYCHAIN_SEARCH_LIST_CHANGED )); then
      if (( ${#ORIGINAL_KEYCHAINS[@]} )); then
        security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" \
          || print -u2 -- "warning: could not restore the original keychain search list"
      else
        security list-keychains -d user -s \
          || print -u2 -- "warning: could not restore the empty keychain search list"
      fi
      KEYCHAIN_SEARCH_LIST_CHANGED=0
    fi
  }
  trap restore_keychain_search_list EXIT INT TERM

  security list-keychains -d user -s "${SIGNING_SEARCH_KEYCHAINS[@]}"
  KEYCHAIN_SEARCH_LIST_CHANGED=1
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY_HASH" \
    --keychain "$SIGNING_KEYCHAIN" \
    "$FRAMEWORKS_PATH/libopus.0.dylib"
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY_HASH" \
    --keychain "$SIGNING_KEYCHAIN" \
    "$BUNDLED_DRIVER_PATH"
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY_HASH" \
    --keychain "$SIGNING_KEYCHAIN" \
    "$APP_PATH"
  restore_keychain_search_list
  trap - EXIT INT TERM
else
  print -u2 -- "warning: stable local signing is not configured; using an ad-hoc signature"
  codesign --force --sign - "$FRAMEWORKS_PATH/libopus.0.dylib"
  codesign --force --sign - "$BUNDLED_DRIVER_PATH"
  codesign --force --sign - "$APP_PATH"
fi
codesign --verify --deep --strict --verbose=2 "$BUNDLED_DRIVER_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$CONTENTS_PATH/Info.plist"

mkdir -p "$DIST_ROOT"
OUTPUT_STAGING="$DIST_ROOT/.Agent Remote.app.staging.$$"
OUTPUT_BACKUP="$DIST_ROOT/.Agent Remote.app.previous.$$"
/bin/rm -rf -- "$OUTPUT_STAGING" "$OUTPUT_BACKUP"
ditto "$APP_PATH" "$OUTPUT_STAGING"
codesign --verify --deep --strict "$OUTPUT_STAGING"
if [[ -e "$OUTPUT_APP_PATH" ]]; then
  /bin/mv "$OUTPUT_APP_PATH" "$OUTPUT_BACKUP"
fi
if /bin/mv "$OUTPUT_STAGING" "$OUTPUT_APP_PATH"; then
  /bin/rm -rf -- "$OUTPUT_BACKUP"
else
  if [[ -e "$OUTPUT_BACKUP" ]]; then
    /bin/mv "$OUTPUT_BACKUP" "$OUTPUT_APP_PATH" || true
  fi
  print -u2 -- "error: could not publish the packaged app; the previous package was restored"
  exit 1
fi

print -r -- "$OUTPUT_APP_PATH"
