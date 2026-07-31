# Solution: the Bluetooth microphone was streaming — the app was filtering it out

Date: 18 July 2026. Written against the problem statement in `problem.md`.

## TL;DR

The controller was almost certainly sending real voice the whole time. The bug
is on the **receive side of this app**, not in the Sony SetState/arming
sequence:

`DualSenseBluetoothAudioPacketBuilder.microphoneOpusFrame(...)` classified a
0x31 input report as a microphone frame only when its payload began with
`d4 ff`. But `d4 ff fe` is exactly what an Opus encoder emits for **encoded
digital silence** at the mic's configuration. Real speech frames are `d4`
followed by arbitrary range-coder bytes and essentially never have `ff` as the
second byte. So the classifier accepted only silent frames and threw away
every frame that contained voice. "18 decoded frames, all peak 0" was a
tautology — the filter selects silence by construction — and every profile
experiment in `problem.md` was unknowingly measuring the filter, not the
controller.

The fix (already applied, compiled, and unit-tested in this working tree) is
to classify microphone feedback the way both working DS5Dongle
implementations do: by **bit 1 of the flag byte that follows the report ID**,
never by packet content.

## Evidence chain

### 1. What the working implementations actually do

From the reference clones used during the investigation:

`DS5Dongle-OLED-Edition/src/main.cpp` (the fork whose Bluetooth mic is
confirmed working end-to-end with Discord/OBS):

```c
// data[0] is the HIDP 0xA1 prefix, so data[1] = report ID, data[2] = flags
if (channel == INTERRUPT && data[1] == 0x31 && ((data[2] >> 1) & 1)
    && len >= 75) {
    if (get_config().bt_mic_enable) mic_add_queue(data + 4);  // 71 bytes
    return;
}
```

`VIIPER/docs/research/dualsense-bluetooth-microphone.md` confirms the same
wire behavior independently for `awalol/DS5Dongle` and `DS5_Bridge`:

> The controller returns a Bluetooth input report `0x31`. **Bit 1 of its flag
> byte marks a microphone packet.** In raw L2CAP framing, the Opus payload
> begins at byte 4: `A1 31 flags ...`. It is a 71-byte Opus frame.

Neither project ever inspects the Opus bytes to decide whether a report is
audio. Translated to what IOHID hands this app (report ID at byte 0):
`report[1]` is the flag byte (bit 1 = mic), `report[2]` is a rolling counter,
`report[3..73]` is the 71-byte Opus packet, `report[74..77]` is the CRC.

### 2. What this app did instead

The pre-fix classifier in
`Sources/DualSenseBridgeCore/DualSenseBluetoothAudioProtocol.swift` required:

```swift
bytes[markerIndex] == 0xd4, bytes[markerIndex + 1] == 0xff
```

i.e. the payload had to begin `d4 ff`.

### 3. `d4 ff fe` is the encoded-silence signature (bench-proven)

Verified today against the app's own bundled
`dist/DualSense Bridge.app/Contents/Frameworks/libopus.0.dylib`, encoding at
the mic stream's exact configuration (48 kHz, stereo TOC, 10 ms frames, hard
CBR, 71-byte packets, complexity 0):

| Input to encoder | First bytes of packet | Frames passing the old `d4 ff` filter |
| --- | --- | --- |
| Digital silence | `d4 ff fe 00 00 00 00 00 00 00 00 00 …` | 5 / 5 |
| Real signal (speech-band tone mix) | `d4 6b 59 58 99 03 01 87 43 54 02 8c …` | **0 / 200** |

The silence output is byte-for-byte the packet observed in the latest
hardware trace. The `ff fe` after the TOC is the CELT range coder encoding its
"silence" symbol (probability 1/32768 → emits `0xFF 0xFE`), followed by CBR
zero padding. Any frame with actual signal replaces those bytes with ordinary
compressed data.

Conclusion: the old filter passes silence with probability ~1 and speech with
probability ~0 (a voice frame's second byte lands on `0xff` only by ~1/256
chance). The app could never have observed voice no matter what the
controller sent.

### 4. The trace anomalies are now fully explained

- **"Frames began only after several seconds"** — the stream armed quickly
  and voice/room-noise frames flowed immediately, but they failed the filter.
  The first frames to *pass* were gated-silence frames (the noise canceller —
  enabled by AudioControl `0x09` — gates the signal to digital zero between
  words/quiet periods).
- **18 frames in ~2.9 s instead of ~100/s** — that is the silence-only subset
  of a healthy ~100 Hz stream (OLED fork documents "Mic in: ~100/s when
  streaming").
- **"This firmware ignores the 0x36-only arming"** (comment in
  `DualSenseBluetoothEnhancedModeEnabler.swift`) — drawn while the filter hid
  nearly all frames. Unproven either way now; the OLED fork proves 0x36-only
  arming works on its controllers.
- **All seven capture profiles "failed identically"** — of course: the
  receive filter guaranteed identical results regardless of transmit state.

### 5. The transmit side already matches the known-working reference

This was verified byte-for-byte, so no SetState change is needed for the
retest. The app's `microphoneArmingState` (the 63-byte block inside the 0x36
report) is **identical** to the OLED fork's `state_init_data` in
`src/state_mgr.cpp`, which is the state its working mic ships with:

| Field (offset in SetStateData) | Value both send | Meaning |
| --- | --- | --- |
| valid_flag0 / valid_flag1 (0, 1) | `0xfd 0xf7` | all audio controls marked valid |
| VolumeHeadphones / VolumeSpeaker (4, 5) | `0x7f 0x64` | |
| VolumeMic (6) | `0x40` | mic gain 64 — nonzero |
| AudioControl (7) | `0x09` | MicSelect=1 (internal), noise-cancel on |
| MuteLightMode (8) | `0x00` | LED off |
| MuteControl / PowerSave (9) | `0x00` | MicMute clear, AudioPowerSave clear |
| AudioControl2 (37) | `0x0a` | beamforming on, speaker comp pre-gain 2 |

The app's separate `internalMicrophoneSourceReport` (0x31 SetState) sets the
same `VolumeMic=0x40`, `AudioControl=0x09`, `AudioControl2=0x0a` with the
correct validity flags, and the unmute report clears MuteControl with
`AllowMuteLight|AllowAudioMute` — all consistent with the standard DualSense
output-report layout. The 0x32 `[0x91][1][0x03]` enable matches upstream
DS5Dongle's `update_mic_status()` exactly, and the 547-byte 0x39 carrier
matches upstream's `audio_bt_task()` layout (`0x91/6/0x7f/64×4/counter`,
`0xd2` dual haptics, `0xd3` dual 200-byte speaker frames).

Note: `problem.md`'s statement that "the known open-source default uses
MicSelect = 0 (automatic)" needs correcting. Upstream's *config default* is
auto — which means it doesn't touch AudioControl at all — but the OLED fork's
working mic ships `MicSelect = 1` + noise-cancel + beamforming + volume 64 in
every keepalive, i.e. exactly the app's first profile. The "minimal
MicSelect=0" experiment is no longer the leading hypothesis; it is a fallback
(see "If the retest is still silent" below).

## The fix (applied in this working tree)

`Sources/DualSenseBridgeCore/DualSenseBluetoothAudioProtocol.swift`:

1. **`microphoneOpusFrame(reportID:bytes:)`** now classifies by the feedback
   flag (`report[1] & 0x02` when the report ID is present, `report[0] & 0x02`
   when not), then slices exactly 71 bytes starting two bytes after the flag
   byte. No content sniffing. Mirrors the dongle's
   `((data[2] >> 1) & 1)` + `data + 4` + length guard.
2. **`faceButtonMask` and `gamepadState`** now exclude audio frames by the
   same flag bit instead of testing whether a payload byte equals `0xd4`.
   This also fixes a latent input bug: a left stick held near 82 % deflection
   put `0xd4` in the Y-axis byte and silently dropped button/state reports.

`Tests/DualSenseBridgeCoreTests/DualSenseBluetoothAudioProtocolTests.swift`:

- Updated the three affected tests to set/clear the flag bit.
- Added `voiceFramesWithoutSilencePrefixAreAccepted()` — the regression test
  that was missing: a frame `d4 2b 91 …` (no silence prefix) must be
  accepted, and the same bytes without the flag must not be treated as audio.

Verification performed here:

- `swift test` (with the module-cache overrides from `problem.md`):
  **36/36 tests pass** (35 pre-existing + 1 new). This build also compiles
  the previously **unbuilt default-input restoration patch** in
  `DualSenseAudioInputManager.swift` / `main.swift`, so that patch is no
  longer "uncompiled" — see below.
- Encode/decode bench proof of the silence signature (table above).

Not yet done (needs the user / hardware): packaging, installing, and the live
controller test. **The currently installed `dist/DualSense Bridge.app` still
contains the old filter and the old input-restore behavior.**

## Review of the interrupted default-input patch

The patch described in `problem.md` is present in the working tree and reads
correctly:

- persists the previous *physical* input UID
  (`bluetoothMicrophone.previousDefaultInputUID.v1`), refusing to save the
  bridge or any virtual device as "previous";
- on stop, restores the saved device only when the bridge is still the
  default (so a user's manual selection is never stomped), falls back to the
  remembered UID → built-in microphone → any built-in → any physical input,
  and unmutes the restored device;
- `main.swift` calls `restoreDefaultInputIfStranded()` at launch, which
  repairs the crash/restart case;
- it now compiles and the full suite passes.

Residual gap (acceptable, document it): if the app is killed inside the
350 ms deactivate window, the bridge stays default until the next launch of
the app repairs it. macOS itself cannot be fixed from a dead process.

## What to do next, in order

1. **Restore normal Mac audio now** (unchanged from `problem.md`): System
   Settings → Sound → Input → MacBook Air Microphone. Required until the new
   build is installed.
2. **Package and install the fixed build:**
   ```sh
   env CLANG_MODULE_CACHE_PATH=/path/to/ephemeral-research/dualsense-swift-module-cache \
       SWIFTPM_MODULECACHE_OVERRIDE=/path/to/ephemeral-research/dualsense-swiftpm-cache \
       swift test            # already green: 36/36
   ./scripts/package-app.sh
   open "/path/to/agent-remote/dist/DualSense Bridge.app"
   ```
3. **(Recommended, 2 minutes) Independently validate the HAL loopback** per
   `problem.md` §B: run `Tools/DualSenseBridgeMicHALTest.c` against the
   installed driver and confirm a nonzero 440 Hz peak. This isolates the one
   remaining downstream link the silence bug could not exercise (nonzero PCM
   → virtual device → input side).
4. **Live retest over Bluetooth** — wake the controller, hold Triangle, speak
   a phrase, release. Expected in `~/Library/Logs/Agent Remote/Agent Remote.log` with the fix:
   - mic Opus frames at **~100/s** (not ~6/s), so frame numbers in the
     hundreds within seconds;
   - `Bluetooth microphone real encoded signal detected on profile: Sony
     internal CHAT/ASR` almost immediately (this also freezes the profile
     fallback on the known-good state — by design);
   - decoded peaks in the thousands while speaking;
   - a summary like `decoded=~300, nonSilent=~200, maximumPeak=20000+` for a
     3 s hold — and a live waveform/transcription in Codex.
5. **Re-verify the release path and Game Center** per `problem.md` §E:
   exactly one Command-O down/up, no Game Center, `explicit device seize=0`
   in the log. (Unchanged by this fix; voice frames were already excluded
   from gamepad parsing, and remain so via the flag bit.)
6. **Confirm input restoration**: after release, the previous input device
   returns automatically; kill -9 the app mid-route and relaunch to confirm
   the stranded-bridge repair.

## If the retest is still silent (contingency)

Only if step 4 still shows all-zero peaks **at ~100 frames/s** does the
transmit-side investigation from `problem.md` §C/§D become relevant again —
and it should then be run with the corrected reference facts:

- First candidate: hold the **OLED working state** (already profile 1:
  `0x09`/`0x0a`, VolumeMic 64, MuteControl 0) stable on a fresh link with
  *no* profile switching, arming only via 0x36 at 4 Hz.
- Second candidate: upstream's auto behavior — send **no** AudioControl at
  all (drop `internalMicrophoneSourceReport`, use a 0x36 whose SetState has
  `AllowAudioControl=0`), letting firmware keep its default source.
- Change one field per fresh Bluetooth session, as `problem.md` already
  prescribes.

If frames are still arriving at only ~6/s after the fix, instrument the raw
input path first (count all 0x31 reports and the flag-bit distribution)
before touching Sony state at all.

## Recommended follow-up cleanups (after voice is confirmed, not before)

1. **Adopt the OLED keepalive model and retire the 50 Hz 0x39 flood.** The
   OLED fork proves the stream arms with a 398-byte 0x36 keepalive at ~4 Hz
   *only until frames arrive* (the stream is sticky), with no speaker lane
   and no 0x32 repetition. The current 20 ms carrier loop caused 102
   backpressure drops in a 7 s session, wastes Bluetooth bandwidth and
   controller battery, and exists only because the silence bug made the 0x36
   path look dead. `microphoneArmingReport()` is already implemented and
   byte-correct; the change is confined to `startMicrophoneKeepalive`.
2. **Remove the capture-profile fallback array** once profile 1 is confirmed;
   cycling AudioControl mid-capture reconfigures the DSP and risks gaps.
3. Keep the no-disable policy exactly as is (do not resurrect the 0x32
   disable burst; the OLED notes confirm there is no documented stop
   command and the stream ends on Bluetooth disconnect).

## Acceptance-criteria status after this change

| Criterion (`problem.md`) | Status |
| --- | --- |
| 1. Touchpad/gestures/mappings still work | Unaffected; gamepad parsing strictly widened (stick-Y=0xd4 reports no longer dropped). 36/36 tests green. |
| 2, 4. Triangle → one Command-O down/up | Unaffected by this fix; already working in the last trace. |
| 3. Non-silent decoded peaks + Codex waveform | Root cause removed; needs the live retest to confirm. |
| 5. No Game Center | Unchanged mitigation (seize + flag-bit exclusion); re-verify per §E. |
| 6, 7. Previous input restored / MacBook mic works after | Restore patch reviewed, now compiled and tested; ships with the next package. |
| 8. Repeat hold/release without reconnect | Expected to work (sticky stream + no disable sent); verify twice in one session. |
| 9. Self-contained open-source only | Preserved — fix is 100 % in-repo; classification logic mirrors MIT-licensed DS5Dongle behavior (attribution comment included). |

## One-paragraph answer to `problem.md`'s "precise question"

No new SetState or arming sequence is required. The sequence the app already
sends — unmute (MuteControl=0), `VolumeMic=64`, `AudioControl=0x09`,
`AudioControl2=0x0a`, 0x32 `[0x91][1][0x03]`, plus 0x36/0x39 carriers with
the mic-enable bit — is byte-equivalent to the state the working OLED dongle
holds while its microphone streams. The controller was answering it with a
~100 Hz Opus stream; the app's receive filter (`d4 ff` prefix match) then
discarded every frame that contained voice, because that prefix is the
encoded-*silence* signature. Classify mic feedback by flag bit 1 of the byte
after the report ID (done in this tree), reinstall, and speech should decode
with nonzero peaks under the state already being sent.
