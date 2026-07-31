# Releasing

Agent Remote currently uses ad-hoc or project-local self-signed code signing.
That is appropriate for reviewed source builds, but it does not establish a
publisher identity and it is not Apple notarization.

## Prepare a release

1. Start from a clean checkout and review `CHANGELOG.md`.
2. Run the commands in `CONTRIBUTING.md` and complete the manual hardware
   matrix for USB and Bluetooth.
3. Build each supported architecture on a native machine with a matching Opus
   installation:

   ```sh
   AGENT_REMOTE_BUILD_ARCH=arm64 ./scripts/create-release-archive.sh
   # Run separately on Intel with AGENT_REMOTE_BUILD_ARCH=x86_64.
   ```

4. Inspect `BUILD-COMPONENTS.txt`, all bundled license files, the app and
   driver architectures, and the ad-hoc signature:

   ```sh
   codesign --verify --deep --strict --verbose=2 "dist/Agent Remote.app"
   lipo -archs "dist/Agent Remote.app/Contents/MacOS/DualSenseBridge"
   lipo -archs "dist/Agent Remote.app/Contents/Frameworks/libopus.0.dylib"
   ```

5. Verify each generated `.sha256` file on a second machine. Tag the exact
   reviewed commit and publish source archives. If app archives are published,
   label them clearly as ad-hoc signed and architecture-specific.

Do not tell users to disable system-wide Gatekeeper protections. Users who do
not trust a binary distribution should build directly from the tagged source.
