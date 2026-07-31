#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}

"$SCRIPT_DIR/package-app.sh"

APP_PATH="$PROJECT_ROOT/dist/Agent Remote.app"
VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist")
ARCHITECTURE=$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/DualSenseBridge")
ARCHIVE_PATH="$PROJECT_ROOT/dist/Agent-Remote-$VERSION-$ARCHITECTURE.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

/bin/rm -f -- "$ARCHIVE_PATH" "$CHECKSUM_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
cd "$PROJECT_ROOT/dist"
/usr/bin/shasum -a 256 "${ARCHIVE_PATH:t}" > "${CHECKSUM_PATH:t}"

print -r -- "$ARCHIVE_PATH"
print -r -- "$CHECKSUM_PATH"
