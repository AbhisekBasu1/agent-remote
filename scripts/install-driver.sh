#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 -- "usage: install-driver.sh /path/to/DualSenseBridgeMic.driver"
  exit 2
fi

SOURCE_DRIVER=$1
TARGET_PARENT="/Library/Audio/Plug-Ins/HAL"
TARGET_DRIVER="$TARGET_PARENT/DualSenseBridgeMic.driver"
EXPECTED_ID="io.github.abhisekbasu1.AgentRemote.MicrophoneDriver"
LEGACY_ID="local.controllerproject.DualSenseBridgeMic"

if [[ -L "$SOURCE_DRIVER" || ! -d "$SOURCE_DRIVER" ]]; then
  print -u2 -- "bundled driver is missing: $SOURCE_DRIVER"
  exit 3
fi

SOURCE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$SOURCE_DRIVER/Contents/Info.plist")
if [[ "$SOURCE_ID" != "$EXPECTED_ID" ]]; then
  print -u2 -- "refusing unexpected source bundle: $SOURCE_ID"
  exit 4
fi
/usr/bin/codesign --verify --deep --strict "$SOURCE_DRIVER"

if [[ -e "$TARGET_DRIVER" ]]; then
  if [[ -L "$TARGET_DRIVER" || ! -d "$TARGET_DRIVER" ]]; then
    print -u2 -- "refusing unexpected target: $TARGET_DRIVER"
    exit 5
  fi
  TARGET_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$TARGET_DRIVER/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$TARGET_ID" != "$EXPECTED_ID" && "$TARGET_ID" != "$LEGACY_ID" ]]; then
    print -u2 -- "refusing to overwrite unexpected target bundle: $TARGET_DRIVER"
    exit 5
  fi
fi

/bin/mkdir -p "$TARGET_PARENT"
STAGING_ROOT=$(/usr/bin/mktemp -d "$TARGET_PARENT/.AgentRemoteMicInstall.XXXXXX")
STAGED_DRIVER="$STAGING_ROOT/DualSenseBridgeMic.driver"
BACKUP_DRIVER="$STAGING_ROOT/Previous.driver"
cleanup() {
  if [[ -e "$BACKUP_DRIVER" ]]; then
    print -u2 -- "warning: previous driver retained for manual recovery at $BACKUP_DRIVER"
  else
    /bin/rm -rf -- "$STAGING_ROOT"
  fi
}
trap cleanup EXIT INT TERM

# Build and verify the complete replacement before touching the live driver.
/usr/bin/ditto --noqtn "$SOURCE_DRIVER" "$STAGED_DRIVER"
STAGED_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$STAGED_DRIVER/Contents/Info.plist")
if [[ "$STAGED_ID" != "$EXPECTED_ID" ]]; then
  print -u2 -- "staged driver has an unexpected bundle identifier: $STAGED_ID"
  exit 6
fi
/usr/sbin/chown -R root:wheel "$STAGED_DRIVER"
/bin/chmod -R a+rX,go-w "$STAGED_DRIVER"
/usr/bin/codesign --verify --deep --strict "$STAGED_DRIVER"

HAD_PREVIOUS=0
if [[ -e "$TARGET_DRIVER" ]]; then
  /bin/mv "$TARGET_DRIVER" "$BACKUP_DRIVER"
  HAD_PREVIOUS=1
fi

if ! /bin/mv "$STAGED_DRIVER" "$TARGET_DRIVER"; then
  if (( HAD_PREVIOUS )); then
    /bin/mv "$BACKUP_DRIVER" "$TARGET_DRIVER" || true
  fi
  print -u2 -- "could not place the staged driver; the previous driver was restored"
  exit 7
fi

if ! /usr/bin/codesign --verify --deep --strict "$TARGET_DRIVER"; then
  /bin/rm -rf -- "$TARGET_DRIVER"
  if (( HAD_PREVIOUS )); then
    /bin/mv "$BACKUP_DRIVER" "$TARGET_DRIVER" || true
  fi
  print -u2 -- "installed driver verification failed; the previous driver was restored"
  exit 8
fi

if (( HAD_PREVIOUS )); then
  /bin/rm -rf -- "$BACKUP_DRIVER"
fi

# launchd immediately restarts Core Audio and loads the newly installed HAL
# plug-in. Existing audio playback may pause briefly during this operation.
/usr/bin/killall coreaudiod 2>/dev/null || true

print -r -- "DualSense Bridge Mic installed"
