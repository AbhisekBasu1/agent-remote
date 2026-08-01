# Changelog

All notable user-facing changes will be documented here.

## Unreleased

### Added

- DualSense lightbar and haptic feedback for Codex and Claude Code sessions.
- Multi-session Fleet focus, player-LED indicators, and exact window routing.
- Touchpad pointer, click, scroll, drag, and macOS Spaces gestures.
- Configurable button and stick-direction shortcuts.
- USB and Bluetooth controller microphone routing through the bundled
  open-source virtual microphone driver.
- Recoverable driver updates and an in-app driver uninstaller.
- A unified Button Mapping assignment view that shows and edits Fleet actions.
- A tested, restorable default controller profile matching the maintainer's
  field-tested shortcuts, microphone binding, and Fleet controls.

### Security and privacy

- Agent event directories and diagnostics are restricted to the current user.
- Codex notification JSON is reduced to a lifecycle event before disk writes.
- Diagnostic output no longer records transcript paths, working directories,
  window titles, or task identifiers.

### Changed

- App and driver bundle identifiers now use the project's GitHub namespace.
  Existing preferences from the pre-release local identifier migrate once;
  macOS may ask for Accessibility approval again after the identifier change.

### Fixed

- Raw controller HID sessions now close before macOS sleeps and reopen after
  wake, preventing a USB-connected DualSense from immediately waking the Mac.
