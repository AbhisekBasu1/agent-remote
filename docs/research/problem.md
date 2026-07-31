# DualSense Bridge on macOS: complete handoff and unresolved Bluetooth microphone problem

Last updated: 18 July 2026 (Asia/Kolkata)

## Executive summary

This project is a native macOS menu-bar application that makes a Sony PS5
DualSense controller useful as a desktop input device. Touchpad pointer
movement, scrolling, taps/clicks, face-button keyboard mappings, and the
Triangle-to-Codex shortcut are substantially working over Bluetooth.

The unresolved problem is the DualSense's **built-in microphone over
Bluetooth**. The application can:

- receive Triangle down and up correctly;
- start and stop Codex's Command-O dictation shortcut correctly;
- explicitly seize the controller's HID device;
- unmute the controller and turn its orange mute light off;
- send Sony Bluetooth audio-control packets;
- receive correctly shaped 71-byte microphone Opus packets;
- decode those packets successfully; and
- route decoded PCM through the project's own open-source Core Audio virtual
  device, `DualSense Bridge Mic`.

However, the packets received from the controller contain **encoded silence**.
The latest real attempt produced 18 decoded frames, all with an exact peak of
zero. Codex therefore shows its listening UI but no waveform and transcribes no
speech.

There is also a new regression: after the route stops, macOS can remain set to
`DualSense Bridge Mic` as its default input. Because the bridge is no longer
feeding it, the MacBook's normal microphone then appears dead in Codex and
other apps. A source patch to repair this was just written, but it has **not
yet been compiled, tested, packaged, or installed**. Until that patch is
shipped, the immediate manual recovery is:

1. Open **System Settings -> Sound -> Input**.
2. Select **MacBook Air Microphone** rather than **DualSense Bridge Mic**.

The current packaged app must not be described as fixed.

## The requested end state

The user wants all of the following:

1. DualSense touchpad pointer movement in every direction, with no jump when a
   finger is removed.
2. Normal trackpad-like behavior: one-finger tap/press for left click,
   two-finger tap/right-side press for right click, two-finger scrolling, and
   dragging.
3. Circle mapped to Enter/Return.
4. Triangle, Square, Cross/X, and Circle configurable as arbitrary keys or
   modifier combinations.
5. A `Use PS5 Mic` toggle beside each face-button mapping.
6. Triangle mapped to Command-O, which Codex globally intercepts to start
   dictation.
7. Holding Triangle should start Codex dictation and controller-mic routing;
   releasing Triangle should release Command-O and stop the route.
8. The built-in controller microphone must work both over USB and Bluetooth.
9. No MetaVoice or other separately installed proprietary/third-party audio
   cable may be required. The repository must remain self-contained and
   open-source for other users.
10. Controller reports must not open Apple Game Center.
11. The user's previous Mac input device must always be restored after the
    controller route ends, disconnects, or the app restarts after a crash.

The user has already granted Accessibility permission repeatedly. Do not treat
Accessibility as the current blocker.

## Machine and project context

- Workspace: `/path/to/agent-remote`
- Packaged app: `/path/to/agent-remote/dist/DualSense Bridge.app`
- Runtime log: `~/Library/Logs/Agent Remote/Agent Remote.log`
- Hardware: M1 MacBook Air (`MacBookAir10,1`)
- OS in the supplied crash reports: macOS 26.3 (25D125)
- Controller: Sony DualSense, product ID `0x0ce6`, vendor ID `0x054c`
- Bluetooth address used by the local reconnect diagnostics:
  `7c-66-ef-64-4b-89`
- Current connection mode: Bluetooth
- Current open-source virtual audio-device UID:
  `DualSenseBridgeMic_UID`

The most recent package was signed and passed code-signature verification.
The latest normal Swift test run passed 35 tests. A later source-only input
restoration patch was made after that test run, so the working tree is ahead of
the packaged app.

## Current status by feature

| Area | Status | Evidence/notes |
| --- | --- | --- |
| Bluetooth connection | Working after the user wakes/reconnects the controller | Latest log shows pairing report length 20 and explicit device-seize result 0. |
| Touchpad pointer | Working | Latest trace contains normal X/Y motion and posted mouse destinations. |
| Horizontal movement | Working in the raw Bluetooth path | Earlier GameController-axis handling was unreliable; the raw report parser fixed it. |
| Finger-release jump | Addressed | Gesture filtering and cursor integration suppress release-to-neutral and new-contact jumps. |
| Tap/click/scroll/drag | Implemented and unit-tested | `GestureEngine.swift` and its tests cover these behaviors. |
| Face-button mapping UI | Implemented | Triangle/Square/Cross/Circle support arbitrary key plus modifiers; a manual chooser avoids globally intercepted shortcuts. |
| Circle -> Enter | Implemented | Default key code is Return (36). |
| Triangle -> Command-O | Working | Latest live trace contains a clean down and a clean up event. |
| Triangle release stopping Codex | Working in the latest trace | The previously stuck shortcut is no longer the observed failure. |
| Physical mic mute button/light | Working in the latest build | User confirmed the physical toggle now changes; latest state reports `micMuted=false`. |
| USB controller microphone | Previously worked natively | The user previously saw Codex waveforms while the controller was attached by USB-C. |
| Bluetooth controller microphone packets | Partially working | 71-byte Opus packets arrive, but only as encoded silence. |
| Virtual Core Audio device | Implemented, installed, and recognized | Project-owned driver is bundled and selected; dedicated loopback tools exist. |
| Actual Bluetooth speech | **Not working** | Latest decoded summary: 18 frames, 0 non-silent, maximum peak 0. |
| Game Center suppression | Improved but should be re-verified | Direct per-device seize now returns success; earlier builds still opened Game Center. |
| Restoring MacBook microphone | **Regressed in installed build** | User reports normal Mac mic no longer works because the virtual input can remain selected. Source-only patch exists but is unbuilt. |

## Architecture now in the repository

### Controller input and desktop behavior

- `Sources/DualSenseBridge/ControllerBridge.swift`
  - Coordinates USB/GameController fallback and raw Bluetooth state.
  - Tracks face-button transitions so every shortcut gets both a down and up.
- `Sources/DualSenseBridgeCore/GestureEngine.swift`
  - Pointer movement, touch reset filtering, scrolling, taps, clicks, and cursor
    integration.
- `Sources/DualSenseBridge/MouseEventEmitter.swift`
  - Emits Quartz mouse events and granular keyboard chord events.
- `Sources/DualSenseBridgeCore/KeyboardShortcut.swift`
  - Stable key/modifier model and ordered modifier/key down/up events.
- `Sources/DualSenseBridge/ButtonMappingWindowController.swift`
  - Mapping UI and a `Use PS5 Mic` checkbox for each face button.
- `Sources/DualSenseBridge/BridgeSettings.swift`
  - Persistent mappings. Defaults: Triangle = Command-O + PS5 mic; Circle =
    Return.

### Raw Bluetooth HID and Sony audio transport

- `Sources/DualSenseBridge/DualSenseBluetoothEnhancedModeEnabler.swift`
  - Opens the Bluetooth DualSense through `IOHIDManager`.
  - Requests full reports with feature report `0x09`.
  - Opens the manager with seize options and also calls
    `IOHIDDeviceOpen(device, kIOHIDOptionsTypeSeizeDevice)` explicitly.
  - Parses raw buttons/touch points and microphone-tagged report `0x31`.
  - Sends microphone state/source reports and `0x32`, `0x36`, or `0x39`
    Bluetooth audio carriers.
  - Maintains one Sony sequence across output-report types.
- `Sources/DualSenseBridgeCore/DualSenseBluetoothAudioProtocol.swift`
  - Sony CRC32 construction (including the `0xA2` output seed).
  - SetState reports, compact stream control, 398-byte `0x36` microphone
    arming report, 547-byte `0x39` full audio carrier, and input parsing.

### Decoding and Core Audio route

- `Sources/DualSenseBridge/BluetoothOpusDecoder.swift`
  - Native Swift dynamic wrapper around bundled `libopus.0.dylib`.
  - Decodes 48 kHz mono, 480-sample microphone frames.
- `Sources/DualSenseBridge/DualSenseAudioInputManager.swift`
  - Selects native USB input when available.
  - For Bluetooth, starts the decoder and the virtual-device output, starts
    HID microphone streaming, then changes macOS's default input to the bridge.
  - Counts decoded frames, non-silent frames, and peak amplitude.
- `Sources/DualSenseBridge/VirtualMicrophonePCMOutput.swift`
  - Writes mono signed 16-bit 48 kHz PCM into the virtual device with a small
    prebuffer and ring buffer.
- `Driver/DualSenseBridgeMic.c`
  - Open-source Core Audio HAL loopback driver derived from Apple's permissive
    NullAudio sample.
  - Exposes an input and output called `DualSense Bridge Mic` and loops output
    frames to input consumers.
- `Tools/DualSenseBridgeMicLoopbackTest.c`
  - In-process FIFO test for the driver.
- `Tools/DualSenseBridgeMicHALTest.c`
  - Loaded-HAL 440 Hz loopback test. This is useful for independently proving
    that nonzero PCM written to the installed driver becomes nonzero input.

The application currently recognizes only `DualSenseBridgeMic_UID`; it does
not fall back to MetaVoice, BlackHole, or another cable.

## What has been tried

### 1. Native GameController touchpad input

The initial implementation used Apple's GameController framework. Vertical
movement appeared, but horizontal motion was limited or erratic, and contact
release sometimes moved the pointer to an edge. Multiple gesture fixes were
made:

- establish a baseline on first contact instead of treating it as movement;
- reset the baseline when a contact changes;
- reject implausible coordinate jumps;
- suppress axis-by-axis release-to-neutral transitions;
- accumulate pointer deltas while WindowServer catches up;
- resynchronize after pauses and display-edge clamping;
- debounce taps separately from movement; and
- parse raw Bluetooth touch points when Apple's abstraction is incomplete.

These changes are covered in `GestureEngineTests.swift` and the latest live log
shows working two-axis pointer input. This is not the current microphone cause.

### 2. Face-button mappings and the stuck Command-O problem

The app added persistent mappings and a manual shortcut chooser because Codex
intercepts Command-O before an ordinary recorder control can observe it.

An early implementation behaved as if Triangle remained pressed, so Codex kept
recording until the MacBook trackpad generated another input. Keyboard
emission was changed to explicit ordered events:

1. Command down
2. O down
3. O up
4. Command up

Raw Bluetooth face-button transitions also now drive the release. The latest
attempt proves this portion is functioning:

```text
[2371296.049] raw Bluetooth Triangle down
[2371296.623] Triangle -> Command-O down
[2371302.994] raw Bluetooth Triangle up
[2371302.994] Triangle -> Command-O up
```

The source log uses the real Command symbol; it is written out above to keep
this document plain-text friendly.

### 3. USB microphone route

When attached by USB-C, the DualSense exposes a native Core Audio microphone.
The user previously saw Codex waveforms and could speak through it. This is
important evidence that the controller's physical microphone itself is not
obviously defective.

Bluetooth does not create the same native Core Audio endpoint on macOS, so the
project implements the Sony audio-over-HID transport and supplies its own
virtual Core Audio device.

### 4. MetaVoice experiment and removal

A MetaVoice virtual cable was considered/used during early routing work. The
user explicitly rejected this as a distributable dependency. Current code
does not support it: `supportedVirtualDevice()` accepts only the project's
own UID, `DualSenseBridgeMic_UID`. Do not reintroduce MetaVoice as the answer.

### 5. Project-owned open-source virtual microphone

The repository now contains, builds, signs, packages, and installs
`DualSenseBridgeMic.driver`. Its source and Apple's retained sample license are
in `Driver/`. The package embeds the driver installer and `libopus` licensing.

The virtual route is visible to Core Audio and can be selected as the default
input. However, because the controller currently decodes to all-zero PCM, this
alone cannot make a Codex waveform appear.

The loaded driver should still be validated independently with
`.build/DualSenseBridgeMicHALTest` or a freshly rebuilt equivalent. That test
writes a known 440 Hz signal to the driver's output and checks its input peak.
Do this before assuming Codex or the HAL driver is broken.

### 6. Python/libopus prototypes and two crashes

Two Python 3.12 diagnostics crashed in `libopus.0.dylib` inside
`opus_encoder_ctl`, called through `ctypes`/`libffi`:

- 18 July 2026 12:22:20 IST, incident
  `<private-crash-incident-1>`
- 18 July 2026 13:12:24 IST, incident
  `<private-crash-incident-2>`

Both were `EXC_BAD_ACCESS`/SIGSEGV caused by an invalid encoder pointer passed
through the variadic control function. The supplied reports are at:

- `<private-diagnostic-attachment-1>`
- `<private-diagnostic-attachment-2>`

These were diagnostic-process crashes, not evidence of a controller or Codex
crash. The production path was moved to Swift plus a typed native libopus
wrapper. Do not use the abandoned Python `ctypes` encoder code again.

### 7. Bluetooth microphone protocol reports

The work was based on open-source DualSense Bluetooth implementations:

- [awalol/DS5Dongle](https://github.com/awalol/DS5Dongle)
- [MarcelineVPQ/DS5Dongle-OLED-Edition](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition)
- [hbashton/VIIPER](https://github.com/hbashton/VIIPER)

Temporary local reference clones made during debugging are currently under:

- `/path/to/ephemeral-research/ds5dongle-reference-20260718`
- `/path/to/ephemeral-research/ds5dongle-oled-20260718`
- `/path/to/ephemeral-research/viiper-dualsense-mic-20260718`

They may disappear after reboot and are not project dependencies.

The following report forms were implemented or tested:

- Bluetooth feature report `0x09` to request the controller's full input mode.
- Bluetooth SetState report `0x31` with Sony CRC to control mute state, mic
  volume, source, DSP selection, and AudioControl2.
- Compact 142-byte `0x32` stream control with subpacket `0x91`, length 1, and
  payload `0x03` for microphone enable.
- Open-source-style 398-byte `0x36` arming report, including:
  - `pkt[4] = 0xff` (mic-enable bit set),
  - the 63-byte known SetState baseline,
  - one silent 64-byte haptic block, and
  - no speaker block.
- Current 547-byte `0x39` full audio carrier, including:
  - mic-enabled config flags `0x7f`,
  - four 64-byte buffer-length fields,
  - two zero haptic frames,
  - two valid 200-byte stereo Opus-silence speaker frames, and
  - Sony CRC.

The full-carrier write path is asynchronous and capped at eight outstanding
writes. A 1 ms timeout was briefly used by mistake and was restored to 1000 ms
(the IOKit callback API's timeout unit is milliseconds). The bounded pipeline
eliminated `kIOReturnNoMemory`, although it still logs backpressure drops.

### 8. Invalid microphone-disable behavior

An attempted `0x32` disable/cleanup transition put this controller firmware
into a state where the microphone could not be re-armed until Bluetooth was
reconnected. Open-source notes describe the stream as sticky and do not
document a dependable mid-session stop command.

Current code therefore:

- does not send the invalid disable on app startup or route stop;
- stops consuming/routing mic frames locally;
- keeps exclusive HID ownership so stale audio-tagged `0x31` reports do not
  reach GameController; and
- drops any residual frames outside an intentional route.

Do not restore the invalid disable bursts without new hardware evidence.

### 9. Game Center opening unexpectedly

Microphone feedback reuses Bluetooth HID report ID `0x31`. When macOS's game
controller stack receives those audio-tagged bytes, it can misread them as
controller buttons, including a system/Home-style action, and open Game
Center.

Opening only `IOHIDManager` with the seize option was not enough; an I/O
registry check showed `ClientSeized=No`. The app now additionally calls
`IOHIDDeviceOpen(..., kIOHIDOptionsTypeSeizeDevice)` for the matched physical
device and keeps it open for the app lifetime. The latest connection logged:

```text
Bluetooth full-report mode enabled; pairing report length=20,
explicit device seize=0, manager report callback active
```

Result `0` is success. This is the strongest Game Center mitigation currently
implemented, but it still needs a deliberate post-change verification because
the user observed Game Center several times under earlier builds.

### 10. Reconnect handling

Two temporary IOBluetooth helpers were compiled:

- `/path/to/ephemeral-research/dualsense-session-reset`
- `/path/to/ephemeral-research/dualsense-session-status`

The reset helper can disconnect the controller successfully but macOS cannot
always wake it again. One run left it disconnected and returned
`0xe00002d6`; the user had to press the physical PS button. Avoid unnecessary
programmatic disconnects, and never assume the reconnect succeeded without
checking state.

### 11. Capture-source profile fallback

The current packaged build tries several SetState AudioControl combinations
while no nonzero encoded payload has been observed:

| Profile | AudioControl | AudioControl2 |
| --- | ---: | ---: |
| Sony internal CHAT/ASR | `0x09` | `0x0a` |
| Legacy internal DSP | `0x0d` | `0x02` |
| Internal CHAT/CHAT | `0x49` | `0x0a` |
| Internal ASR/ASR | `0x89` | `0x0a` |
| Raw internal array | `0x01` | `0x08` |
| Raw internal CHAT/CHAT | `0x41` | `0x08` |
| Raw internal ASR/ASR | `0x81` | `0x08` |

The user's latest roughly seven-second hold did **not** meaningfully exercise
all seven. It started on the first profile, switched through the next three,
and reached `raw internal array` only as the route stopped. Therefore, do not
claim that all profile values were disproved.

More importantly, all current profiles force `MicSelect = 1` (internal only).
The known open-source default uses `MicSelect = 0` (automatic), often with only
`AllowAudioControl` set and without forcing mic volume or AudioControl2. That
minimal automatic-source state has not yet been cleanly tested on a fresh
Bluetooth session in this macOS implementation and is the leading packet-state
hypothesis.

## Decisive latest hardware trace

The latest user attempt occurred after a fresh controller wake and after the
build with direct device seizure and profile fallback was installed.

Connection and ordinary controller input worked:

```text
[2371283.521] Bluetooth full-report mode enabled; pairing report length=20,
              explicit device seize=0, manager report callback active
[2371283.526] raw Bluetooth DualSense attached under continuous HID isolation
[2371293.065] primary action deltaX=-0.002084... deltaY=-0.005560...
```

Triangle, unmute, routing, and Command-O all worked:

```text
[2371296.049] raw Bluetooth Triangle down
[2371296.565] Bluetooth physical microphone unmute report #1, result=0
[2371296.579] Bluetooth physical microphone unmute report #2, result=0
[2371296.592] Bluetooth physical microphone unmute report #3, result=0
[2371296.606] Bluetooth microphone capture profile selected:
              Sony internal CHAT/ASR, result=0
[2371296.620] Bluetooth microphone HID return stream enabled
[2371296.623] Bluetooth PS5 mic routed through DualSense Bridge Mic
[2371296.623] Triangle -> Command-O down
```

The controller's normal status was unmuted:

```text
micButton=false, micMuted=false, headphones=false,
micConnected=false, externalMic=false
```

`micConnected=false` is probably the external/headset-jack microphone status,
not proof that the built-in array is absent.

Frames began only after several seconds and were all exact encoded silence:

```text
[2371300.489] Bluetooth microphone fallback profile: internal CHAT/CHAT,
              result=0
[2371300.670] Bluetooth microphone Opus frame #1, bytes=71,
              prefix=d4 ff fe 00 00 00 00 00 00 00 00 00
[2371300.671] Bluetooth microphone decoded frame #1, peak=0
[2371300.684] Bluetooth microphone Opus frame #2, bytes=71,
              prefix=d4 ff fe 00 00 00 00 00 00 00 00 00
[2371300.685] Bluetooth microphone decoded frame #2, peak=0
[2371300.714] Bluetooth microphone Opus frame #3, bytes=71,
              prefix=d4 ff fe 00 00 00 00 00 00 00 00 00
[2371300.715] Bluetooth microphone decoded frame #3, peak=0
```

Release was correct, but the audio summary was silent:

```text
[2371302.994] raw Bluetooth Triangle up
[2371302.994] Triangle -> Command-O up
[2371303.565] Bluetooth microphone HID duplex stream stopped;
              inputFrames=18, queuedOutputFrames=81, pendingOutputFrames=3
[2371303.565] Bluetooth microphone audio summary:
              decoded=18, nonSilent=0, maximumPeak=0
[2371303.593] Bluetooth microphone writes drained without invalid disable;
              completed=80, failed=0, backpressureDrops=102
```

This proves that the primary blocker is before the decoder and virtual device:
the DualSense is emitting a valid silence bitstream instead of microphone
speech. It does not prove that every downstream piece is perfect, so the HAL
loopback test is still worth running independently.

## Newly discovered default-input regression

`DualSenseAudioInputManager` saves the current default device before selecting
the bridge and attempts to restore it 350 ms after the shortcut is released.
In repeated/restarted sessions, however, the "saved" device can already be
`DualSense Bridge Mic`; the in-memory original is also lost if the app crashes
or is forcibly replaced. The stop code then restores the bridge to itself or
has no valid prior ID.

The user has now reported that speaking into the MacBook microphone produces
no audio. The likely immediate state is that `DualSense Bridge Mic` is still
the system default while no producer is active.

A source patch was just applied to:

- `Sources/DualSenseBridge/DualSenseAudioInputManager.swift`
- `Sources/DualSenseBridge/main.swift`

It adds:

- persistent storage of the previous physical input UID;
- rejection of the project virtual UID as a saved "previous" device;
- preference for the built-in physical microphone as a fallback;
- unmuting the restored device;
- recovery at app launch if the virtual device is stranded as default; and
- diagnostic logging for restoration success/failure.

**Important:** this patch was interrupted by the request for this document. It
has not been compiled or tested and is not in the currently installed
`dist/DualSense Bridge.app`. Review it first, run the complete test suite, then
package/relaunch it. In the meantime, manually select MacBook Air Microphone in
System Settings.

## Facts established versus assumptions

### Established by logs or user observation

- Accessibility is granted.
- The controller reconnects and produces raw Bluetooth input.
- Touchpad X and Y movement work in the latest raw path.
- Triangle down and up are both received.
- Command-O down and up are both posted.
- The controller reports its mute latch as false during the attempt.
- The app successfully submits control and audio reports (`IOReturn == 0`).
- Explicit per-device seize succeeds in the latest build.
- 71-byte microphone Opus packets arrive.
- `libopus` decodes them to 480 samples without an error.
- Every decoded sample in the latest attempt is zero.
- No actual Bluetooth speech reaches Codex.
- The installed build can strand the virtual microphone as default.
- USB previously produced real microphone waveforms.

### Not yet established

- That the minimal `MicSelect=auto` SetState used by the working dongle
  projects produces speech on this controller/firmware.
- That a stable, exact `0x36`-only 4 Hz arming flow on a fresh link works when
  no `0x39` or repeated `0x32` traffic is interleaved.
- That the installed HAL loopback passes a fresh known-tone test right now.
- That direct device seizure prevents every future Game Center launch (it is
  promising, but needs a clean user test).
- That the just-written default-input recovery patch compiles and behaves
  correctly.

## Recommended next investigation sequence

This ordering minimizes repeated user speaking and separates the layers.

### A. Recover and protect the MacBook input first

1. Manually restore **MacBook Air Microphone** now.
2. Review the unbuilt default-input patch.
3. Add focused tests around device-selection policy if Core Audio can be
   abstracted behind a small protocol.
4. Compile, run tests, package, and restart the app.
5. Verify that releasing Triangle restores the exact prior physical input and
   that relaunch repairs a stranded bridge input.

Do not continue microphone transport experiments while ordinary Mac audio is
left broken.

### B. Prove the virtual device independently

1. Rebuild/run `Tools/DualSenseBridgeMicLoopbackTest.c`.
2. Rebuild/run `Tools/DualSenseBridgeMicHALTest.c` against the installed
   driver.
3. Confirm a nonzero 440 Hz peak is visible at the input side.
4. If necessary, record several seconds from `DualSense Bridge Mic` with an
   AVAudioEngine/AudioUnit probe rather than using Codex as the only meter.

If this fails, fix the HAL route before touching Sony packets. If it passes,
the all-zero controller payload remains the primary problem.

### C. Reproduce the known working Sony state exactly

On one fresh Bluetooth link, avoid speculative profile switching and use the
minimal known open-source state:

1. Keep direct HID device seizure active.
2. Send a minimal SetState with only `AllowAudioControl=1` and
   `MicSelect=0` (auto). Do not force mic volume, noise cancellation,
   beamforming, or AudioControl2 in this first test.
3. Explicitly clear `MicMute` and `AudioPowerSave` with a correctly flagged
   SetState report.
4. Send the exact 398-byte `0x36` microphone-enable report at approximately
   4 Hz while no mic frames have arrived.
5. As soon as frames arrive, stop the arming reports and let the sticky stream
   run; do not continue 50 Hz `0x39` traffic.
6. Log the complete 71-byte payload or at least an OR/nonzero count, decoded
   peak, and frame cadence.
7. Play a known audible phrase from the Mac speaker or record a controlled
   local sound so the user does not need to repeatedly improvise speech.

This is closer to the OLED fork's documented working behavior than the current
adaptive 50 Hz full-carrier loop.

### D. Only then compare alternative source/DSP states

If minimal auto remains silent:

- try minimal internal-only (`MicSelect=1`) without changing other bits;
- then add mic volume 64;
- then test noise cancellation;
- then test AudioControl2/beamforming;
- change only one field per fresh run;
- keep each source stable long enough to cover the delayed frame burst; and
- reconnect only when a controller-side state transition genuinely requires
  it.

The current profile list changes multiple fields simultaneously, making it
hard to identify which bit silences or enables the path.

### E. Re-verify Game Center and shortcut release

For every final candidate:

- confirm the connection log includes `explicit device seize=0`;
- hold and release Triangle;
- confirm exactly one Command-O down and one up;
- confirm Game Center does not open; and
- confirm no audio-tagged report reaches Apple's GameController path.

## Commands and artifacts useful to the next agent

Run Swift tests:

```sh
env CLANG_MODULE_CACHE_PATH=/path/to/ephemeral-research/dualsense-swift-module-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/path/to/ephemeral-research/dualsense-swiftpm-cache \
    swift test
```

Package/sign the app:

```sh
./scripts/package-app.sh
```

Runtime log:

```sh
tail -n 300 "$HOME/Library/Logs/Agent Remote/Agent Remote.log"
```

Launch the ordinary app:

```sh
open "/path/to/agent-remote/dist/DualSense Bridge.app"
```

Launch the built-in 20-second mic self-test (currently gives up if the
controller does not connect during its short initial retry window):

```sh
open -n "/path/to/agent-remote/dist/DualSense Bridge.app" \
  --args --microphone-self-test
```

The self-test's connection-wait behavior should be improved before it is used
for unattended late reconnects.

## Constraints and pitfalls

- Do not ask the user to re-enable Accessibility again; it is already trusted.
- Do not reintroduce MetaVoice as a dependency.
- Do not claim Bluetooth microphone support from button activity alone.
  Success requires nonzero decoded PCM and user-confirmed speech/waveform.
- Do not confuse the mute light changing with audio data flowing.
- Do not use the abandoned Python `ctypes` libopus encoder probes.
- Do not send the previously attempted undocumented disable burst; it can make
  the microphone unrearmable until reconnect.
- Do not leave `DualSense Bridge Mic` selected after the route ends.
- Do not kill or reconnect the controller unnecessarily; macOS cannot always
  wake it without a physical PS-button press.
- Preserve explicit HID seizure or Game Center may interpret proprietary audio
  packets as controller actions.
- Distinguish the current source tree from the older packaged app. The latest
  source patch is not installed.

## Acceptance criteria

The work is complete only when all of these are true in one Bluetooth session:

1. Touchpad movement, taps, clicks, scroll, and face-button mappings still
   work.
2. Holding Triangle starts Codex exactly once.
3. Speech into the controller produces clearly nonzero decoded peaks and a
   visible Codex waveform/transcription.
4. Releasing Triangle posts the full Command-O key-up sequence and stops the
   recording route.
5. Game Center does not open.
6. The previous Mac input device is restored automatically.
7. The MacBook microphone works immediately afterward.
8. Repeating the hold/release cycle works without reconnecting the controller.
9. The solution uses only code and open-source components distributed in this
   repository.

## Precise question for another agent

Given the verified transport behavior above, what exact DualSense Bluetooth
SetState and mic-enable sequence will make the controller emit **non-silent**
71-byte Opus frames from its built-in microphone on macOS IOHID, while keeping
the device exclusively seized and avoiding a controller-side disable that
requires reconnecting? The first candidate to test should be a stable,
minimal, automatic-microphone (`MicSelect=0`) state followed by the upstream
`0x36` 4 Hz arming flow, with all speculative DSP overrides removed.
