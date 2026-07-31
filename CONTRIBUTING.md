# Contributing

Thanks for helping improve Agent Remote. Small, focused changes with tests and
clear hardware assumptions are easiest to review.

## Development requirements

- macOS 13 or newer
- Xcode 16 or newer with a Swift 6 toolchain
- Homebrew Opus (`brew install opus`) for app packaging
- A Sony DualSense (VID `054c`, PID `0ce6`) for hardware verification

Clone the repository, then run:

```sh
mkdir -p .build/ModuleCache
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift test --disable-sandbox --scratch-path .build \
  -Xswiftc -module-cache-path -Xswiftc .build/ModuleCache
./scripts/package-app.sh
```

`package-app.sh` builds for the current machine by default. Set
`AGENT_REMOTE_BUILD_ARCH=arm64` or `x86_64` only when `OPUS_PREFIX` points to a
matching Opus installation.

Local builds use an ad-hoc signature unless the optional project-local signing
identity has been configured. Never commit `.local-signing`, packaged apps,
recordings, transcripts, model caches, or diagnostic logs.

## Before opening a pull request

1. Run the Swift tests and shell syntax checks.
2. Package the app from a clean checkout.
3. Add tests for pure logic in `DualSenseBridgeCore`.
4. Update user-facing documentation for behavior or permission changes.
5. Confirm `git diff --check` is clean and inspect the complete diff for local
   paths or private data.

Hardware-facing changes should record the tested matrix in the pull request:

- macOS version and Apple silicon or Intel;
- USB, Bluetooth, or both;
- controller model/revision and firmware where known;
- pointer/buttons, lightbar, haptics, microphone, and driver lifecycle paths
  affected by the change.

Do not attach real agent transcripts or voice recordings. Reduce failures to
synthetic fixtures and redact usernames, task IDs, working directories, device
serials, and crash identifiers.

## Style and licensing

Follow the surrounding Swift and C style, keep comments focused on non-obvious
hardware or concurrency constraints, and avoid unrelated rewrites. By
submitting a contribution, you agree that it may be distributed under the
repository's MIT license. Third-party code must have a compatible license and
an entry in `THIRD_PARTY_NOTICES.md`.
