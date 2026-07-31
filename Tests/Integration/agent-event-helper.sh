#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-remote-event-test.XXXXXX")
trap '/bin/rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"

HOME="$TEST_HOME" "$PROJECT_ROOT/App/agent-remote-event" codex-notify \
  '{"type":"agent-turn-complete","last-assistant-message":"PRIVATE_SENTINEL"}'

SPOOL="$TEST_HOME/Library/Application Support/DualSenseBridge/agent-events"
EVENT_FILE=$(find "$SPOOL" -type f -name 'evt-*' -print -quit)
test -n "$EVENT_FILE"
test "$(stat -f '%Lp' "$SPOOL")" = "700"
test "$(stat -f '%Lp' "$EVENT_FILE")" = "600"
grep -qx 'event=done' "$EVENT_FILE"
grep -qx 'source=codex' "$EVENT_FILE"
if grep -q 'PRIVATE_SENTINEL' "$EVENT_FILE"; then
  echo "Codex notification content leaked into the event spool" >&2
  exit 1
fi

BEFORE_COUNT=$(find "$SPOOL" -type f -name 'evt-*' | wc -l | tr -d ' ')
HOME="$TEST_HOME" "$PROJECT_ROOT/App/agent-remote-event" codex-notify \
  '{"type":"unrelated","prompt":"PRIVATE_SENTINEL"}'
HOME="$TEST_HOME" "$PROJECT_ROOT/App/agent-remote-event" invalid-event ignored
AFTER_COUNT=$(find "$SPOOL" -type f -name 'evt-*' | wc -l | tr -d ' ')
test "$BEFORE_COUNT" = "$AFTER_COUNT"

HOME="$TEST_HOME" "$PROJECT_ROOT/App/agent-remote-event" attention \
  'custom source/with private text'
LATEST_FILE=""
for candidate in "$SPOOL"/evt-*; do
  if [ "$candidate" != "$EVENT_FILE" ]; then
    LATEST_FILE="$candidate"
  fi
done
test -n "$LATEST_FILE"
grep -qx 'event=attention' "$LATEST_FILE"
grep -qx 'source=customsourcewithprivatetext' "$LATEST_FILE"

echo "agent event helper integration test passed"
