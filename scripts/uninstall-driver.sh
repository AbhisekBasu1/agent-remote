#!/bin/zsh
set -euo pipefail

if (( $# != 0 )); then
  print -u2 -- "usage: uninstall-driver.sh"
  exit 2
fi

TARGET_DRIVER="/Library/Audio/Plug-Ins/HAL/DualSenseBridgeMic.driver"
EXPECTED_ID="io.github.abhisekbasu1.AgentRemote.MicrophoneDriver"
LEGACY_ID="local.controllerproject.DualSenseBridgeMic"

if [[ ! -e "$TARGET_DRIVER" ]]; then
  print -r -- "DualSense Bridge Mic is not installed"
  exit 0
fi
if [[ -L "$TARGET_DRIVER" || ! -d "$TARGET_DRIVER" ]]; then
  print -u2 -- "refusing unexpected target: $TARGET_DRIVER"
  exit 3
fi

TARGET_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$TARGET_DRIVER/Contents/Info.plist" 2>/dev/null || true)
if [[ "$TARGET_ID" != "$EXPECTED_ID" && "$TARGET_ID" != "$LEGACY_ID" ]]; then
  print -u2 -- "refusing to remove unexpected target bundle: $TARGET_DRIVER"
  exit 4
fi

/bin/rm -rf -- "$TARGET_DRIVER"

# launchd restarts Core Audio and releases the removed HAL plug-in. Existing
# audio playback may pause briefly during this operation.
/usr/bin/killall coreaudiod 2>/dev/null || true

print -r -- "DualSense Bridge Mic uninstalled"
