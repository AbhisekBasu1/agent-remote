# DualSense Bluetooth microphone on macOS: fourth AI handoff

Date: 22 July 2026

This is the current, self-contained handoff for the remaining audio-quality
problem in DualSense Bridge. It supersedes the state descriptions in
`problem.md`, `problem2.md`, and `problem3.md`, while those files and
`solution.md`, `solution2.md`, and `solution3.md` remain useful investigation
history.

The latest user verdict, after testing the build described here, is:

> Better, still not perfect.

That distinction matters. The Bluetooth controller microphone now works and
is understandable, but the goal is not merely intelligibility. The user wants
speech that is clean, natural, and close to the simultaneous MacBook Air
microphone reference, without the remaining robotic/processed distortion or
recognition errors.

## Executive summary

The application is functionally working:

- A DualSense connected over Bluetooth is owned through raw IOKit HID.
- Touchpad pointer movement, taps, clicks, scrolling, and face-button mappings
  work.
- Game Center no longer opens during normal controller use.
- Triangle can hold Command-O for Codex dictation and releases it correctly.
- The controller microphone can be unmuted; the physical mute button and light
  work.
- The built-in microphone's real Opus packets reach the app and decode.
- A bundled, project-owned Core Audio driver exposes the result as
  **DualSense Bridge Mic**. MetaVoice, BlackHole, and other third-party audio
  cables are not required.
- Square starts/stops a diagnostic recording, saves the exact virtual-mic
  output, saves the untouched decoded frames/counters/Opus packets, and plays
  the processed recording.
- The menubar can simultaneously record a MacBook microphone reference into
  the same folder.
- Decoder and AudioQueue prewarming prevent the former first-word loss.
- The latest recording had 100% AudioQueue signal duty and zero underruns.

The unresolved issue is the fidelity of the Bluetooth voice. The best build
so far uses the controller's new **Natural** source profile and Apache Sonic
pitch-period expansion. It is at approximately the correct speed and is more
understandable than prior builds, but it remains audibly robotic/distorted and
still loses words relative to the MacBook reference.

The central constraint remains severe: the DualSense logically generates
about 100 ten-millisecond microphone frames per second, while this Mac's
Bluetooth HID path delivers only about 43 real microphone frames per second.
In the newest take, 719 of 1,263 logical source-frame positions (56.93%) never
arrived. The current pipeline expands the 43.07% that survived by about 2.32x.
That restores duration and pitch, but it repeats surviving speech material;
it cannot recreate phonemes that were never received.

There are now two plausible contributors to the remaining sound:

1. **Dominant, proven:** extreme structured frame absence plus high-ratio
   pitch-period repetition in the Mac-side reconstruction.
2. **Secondary, partly tested:** controller-side microphone-array processing.
   Disabling the controller noise canceller in the newest build made the
   result better, but beamforming remains enabled and the second Opus channel
   has not been freshly evaluated under this Natural profile.

A new agent should not start with another small EQ adjustment. The most useful
next work is a controlled source/channel experiment, definitive Bluetooth
transport evidence, or a reconstruction method that can beat the current
Sonic baseline across several archived recordings.

## Newest canonical comparison

These are the files from the user's latest test of the installed Natural-mode
build:

- MacBook reference:
  `/path/to/private-audio-fixtures/MacBook Mic Reference 2026-07-22 21.32.04.wav`
- Processed controller output (exactly what the virtual mic emitted):
  `/path/to/private-audio-fixtures/DualSense Mic 2026-07-22 21.32.20.wav`
- Untouched decoded controller channel-0 frames, concatenated without timing
  reconstruction:
  `/path/to/private-audio-fixtures/Diagnostics/DualSense Mic 2026-07-22 21.32.20 Raw.wav`
- Controller microphone counters:
  `/path/to/private-audio-fixtures/Diagnostics/DualSense Mic 2026-07-22 21.32.20 Counters.txt`
- Exact received Opus packets:
  `/path/to/private-audio-fixtures/Diagnostics/DualSense Mic 2026-07-22 21.32.20 Opus.bin`
- Session log:
  `~/Library/Logs/Agent Remote/Agent Remote.log`

The user spoke approximately:

> Okay, so this is another recording, and I hope it does better than last
> time, because we are really working hard at this, and I hope this works.

An offline Faster Whisper `tiny.en` run is only a proxy for intelligibility,
not a substitute for listening, but it exposes the remaining gap clearly.

MacBook reference:

> Okay, so this is another recording and I hope it does better than last time
> because we are really working hard at this and I hope this works.

Processed DualSense:

> Okay, so this is another recording and I will print this and then last time
> because we are We are working hard at this time for this one.

Raw compacted DualSense frames:

> Okay, so this is another coin, and I'm going to spend that last time,
> because we are part of this, I know this one.

The processed path is materially better than raw and the user also reports an
audible improvement, but important words are still altered. This is not yet a
dictation-quality result.

## Exact newest transport and output evidence

| Measurement | Latest value |
|---|---:|
| Capture profile | Natural internal array |
| Controller noise cancellation | Off |
| Controller beamforming | On |
| Controller microphone gain | 24 of 64 |
| Received real Opus frames | 544 |
| Logical 10 ms positions from counter | 1,263 |
| Missing logical positions | 719 (56.93%) |
| Required duration ratio | 2.321691x |
| Applied fixed Sonic ratio | 2.3172x |
| Learned ratio for next session | 2.3217x |
| Real mic reports | 42.9/s |
| Genuine gamepad reports | 22.4/s |
| Combined input reports | 65.2/s |
| Raw genuine PCM duration | 5.440 s |
| Counter timeline duration | 12.630 s |
| Saved processed duration | 13.120 s |
| MacBook file duration (includes extra lead/tail) | 19.234 s |
| Raw maximum sample peak | 15,083 of 32,767 |
| Processed maximum sample peak | 16,269 of 32,767 |
| Output signal duty | 100.0% |
| Output underruns/gaps | 0 / 0 ms |

The missing-frame pattern from the archived counter file is:

```text
counter deltas:
  +1 x 136
  +2 x 135
  +3 x 259
  +4 x 5
  +5 x 4
  +9 x 2
  +10 x 1
  +11 x 1

received=544
generated=1263
missing=719
required ratio=2.321691
```

Interpreted as genuine islands and holes:

```text
genuine consecutive islands:
  10 ms x 273
  20 ms x 133
  40 ms x 1

holes:
  10 ms x 135
  20 ms x 259
  30 ms x 5
  40 ms x 4
  80 ms x 2
  90 ms x 1
  100 ms x 1
```

About 90.8% of all missing samples are in 10-20 ms holes. Real audio
re-anchors the timeline frequently, but more timeline is synthetic than real.

The combined 0x31 transport sequence was perfectly contiguous:

```text
records=828, deltas=[+1 x 827], missed=0, duplicates=0, backwards=0
```

The independent microphone counter still skipped logical audio positions.
This means the app did not simply lose 719 callbacks after reports arrived.
The available evidence is consistent with the controller transmitting only
the newest mic frame on the Bluetooth service opportunities macOS gives it.

The output itself was continuous. Therefore neither AudioQueue starvation nor
virtual-driver silence explains the remaining robotic quality in this take.

## Codec facts

- Every archived microphone packet is 71 bytes.
- The Opus TOC is `0xd4`.
- This is a 10 ms, stereo, super-wideband, CELT-only Opus packet.
- CELT-only Opus packets do not provide SILK LBRR/in-band FEC. Asking libopus
  for FEC cannot recover the omitted frames.
- The packet is decoded as stereo and channel 0 is selected explicitly.
  Creating a mono Opus decoder downmixed the two encoded lanes and previously
  caused hollow/comb-like coloration.

Do not propose Opus in-band FEC as a new solution unless the actual packet
format first changes away from TOC `0xd4`.

## Current application architecture

### Controller transport and source profile

Relevant file:

`Sources/DualSenseBridge/DualSenseBluetoothEnhancedModeEnabler.swift`

The app:

- Opens and continuously isolates the raw Bluetooth DualSense HID device.
- Enables Sony full-report mode.
- Requests a 5,000 microsecond HID report interval. IOKit reports that value
  back, but actual combined delivery remains about 63-69 reports/s.
- Clears the controller's physical mute latch three times before arming.
- Sends a small audio-stream arming report.
- Sends LED-only blue/amber state updates so recording UX cannot overwrite
  the audio configuration.
- Sends no periodic output during healthy capture; a prior high-rate inert
  output pulse did not improve incoming rate and was removed.

The current default profile is:

```text
name: Natural internal array
AudioControl:  0x01
AudioControl2: 0x08
```

According to the open-source DS5Dongle structure definitions, that means:

- internal microphone selected;
- echo cancellation off;
- controller noise cancellation off;
- input path `CHAT_ASR`;
- beamforming enabled.

The menubar exposes **Bluetooth Mic Sound**:

- **Natural (Recommended)**: `0x01 / 0x08`.
- **Sony Voice Chat**: `0x09 / 0x0a`, enabling Sony noise cancellation.

A change made during a recording deliberately applies to the next take.

### Opus decode

Relevant file:

`Sources/DualSenseBridge/BluetoothOpusDecoder.swift`

The app loads bundled libopus, creates a 48 kHz stereo decoder, decodes one
480-sample-per-channel frame from each genuine packet, and emits channel 0.
It does not advance the primary decoder across counter holes.

The comment calls channel 0 `CHAT` and channel 1 `ASR`, based on the earlier
Sony `CHAT_ASR` capture. That choice substantially improved the prior source
over libopus mono downmix. It has not yet been revalidated on the newest
Natural (`0x01 / 0x08`) archive. This is an important cheap next experiment.

### Cleanup, timing, and reconstruction

Relevant files:

- `Sources/DualSenseBridge/VirtualMicrophonePCMOutput.swift`
- `Sources/DualSenseBridgeCore/DualSenseSpeechCleanupFilter.swift`
- `Sources/DualSenseBridgeCore/DualSenseAdaptiveSpeechTiming.swift`
- `Sources/DualSenseBridgeCore/DualSenseSonicSpeechTimeStretcher.swift`
- `Sources/CSonic/sonic.c`

The live pipeline is currently:

```text
real Opus packet
  -> stereo libopus decode
  -> select channel 0 (480 genuine mono samples)
  -> 70 Hz high-pass
  -> +3 dB low shelf at 180 Hz
  -> two cascaded 5 kHz low-pass biquads
  -> Apache Sonic quality=1, fixed utterance ratio (~2.32x)
  -> +2.5 dB low shelf at 180 Hz
  -> AudioQueue / project-owned virtual microphone
```

The former -2 dB/500 Hz finishing dip is disabled in the live Sonic path
because archived recognition became slightly worse with it.

The timing counter is observed throughout a take, but the live Sonic ratio is
held fixed for the complete utterance. At session end, the exact cumulative
counter ratio is persisted for the next take. This avoids audible speed
pumping while a ratio estimate converges. The default for a clean install is
2.30; the latest take used 2.3172 and learned 2.3217.

Sonic is vendored under the Apache 2.0 license. It performs pitch-period
insertion/removal rather than resampling or a phase vocoder. It has produced
the best overall result so far, but at a 2.32x expansion it necessarily
repeats a large amount of surviving material, including some unvoiced speech.

### Playout and virtual microphone

Relevant files:

- `Sources/DualSenseBridge/VirtualMicrophonePCMOutput.swift`
- `Driver/DualSenseBridgeMic.c`
- `Sources/DualSenseBridge/BundledMicrophoneDriverManager.swift`

The corrected AudioQueue uses:

- 48 kHz mono PCM;
- 21,600-sample (450 ms) initial prebuffer;
- 7,200-sample (150 ms) resume threshold;
- a bounded edge smoother only for genuine output underruns.

The latest take had no underrun, so the 450 ms reservoir is now doing its job.
The Core Audio driver is bundled and installed under the app's own UID. The
previous physical input is restored after capture, including after abnormal
termination recovery. Do not reintroduce MetaVoice or change the system mic
globally as a workaround.

## What changed since problem3.md / solution3.md

### 1. The project SOLA implementation was replaced by Apache Sonic

The prior 30 ms/15 ms project SOLA was understandable but persistently
robotic. A wide offline search showed Sonic quality 1 with a fixed ratio to be
the best general compromise across the archived speech. It improved the live
sound enough for the user to call successive versions the best so far.

Sonic quality 0, quality 1, plain tone, shelf tone, fixed ratios, and dynamic
ratios were replayed. Results varied by archive; no alternate setting beat the
selected quality-1/fixed-ratio path consistently. Dynamic ratio updates caused
timing/recognition regressions, so the ratio is now learned between utterances.

### 2. Decoder-state alternatives were rejected reproducibly

`Tools/AudioLab/opus_state_replay.py` reads an archived `DSOPUS01` packet
stream and renders four decoder-state variants. On the 17:42 archive:

- `skip` reproduced the app's archived Raw WAV sample-exactly;
- advancing the decoder with PLC through every hole badly garbled speech;
- resetting the decoder at every gap badly garbled speech;
- resetting it for every real packet also badly garbled speech.

The primary decoder must continue decoding genuine packets continuously while
skipping absent positions unless a genuinely different codec strategy proves
better offline.

### 3. The detailed counter-anchored proposal was implemented once and failed

`solution3.md` proposed counter-anchored voiced/noise/LPC-style hole filling.
An offline first implementation remains at:

`/path/to/ephemeral-research/anchored_reconstruct_v1.py`

It produced hybrid, noise, and voiced candidates for the 17:42 archive under:

`/path/to/ephemeral-research/anchored-v1/`

Their durations were correct, but listening and recognition were drastically
worse than Sonic: speech became fragmented, synthetic, or unintelligible.
This does not mathematically disprove every anchored reconstructor; it does
mean a new agent must inspect and identify a materially different mechanism
before repeating that proposal. Correct counter placement alone did not make
the synthetic holes transparent.

### 4. The controller noise canceller was disabled

The previous best source used Sony `0x09 / 0x0a` (internal mic, controller
noise cancellation on, beamforming on). The current build added a persisted
menubar choice and defaults to `0x01 / 0x08` (noise cancellation off,
beamforming still on).

The newest take's log proves that Natural—not merely the menu state—was sent
to the controller. The user reported it was better, so preserve this as the
default and baseline. It did not remove all distortion.

### 5. Startup and output continuity were hardened

- libopus and the virtual AudioQueue are prepared at app launch.
- Subsequent takes reuse the prepared queue with a 0 ms Core Audio open delay.
- The initial reservoir was increased to 450 ms.
- The latest test did not clip the first word and had zero output gaps.

These are solved areas, not current root causes.

## Approaches already tried and their verdicts

| Approach | Verdict |
|---|---|
| Mono libopus decode/downmix | Hollow/comb-like; stereo channel-0 selection was better on the earlier Sony source |
| Sony Voice Chat source (`0x09/0x0a`) | Worked and was previously best, but Natural is now subjectively better |
| Natural source (`0x01/0x08`) | Current best; still robotic/distorted |
| Ordinary Opus PLC for every missing counter position | More than half the output became PLC; barely audible or unintelligible |
| Advance main decoder state while discarding PLC | Corrupted later genuine frames |
| Shadow/cloned Opus PLC | Worse recognition and sound than current path |
| Reset decoder on gaps/every packet | Badly garbled; rejected by reproducible replay tool |
| Repeat missing 10 ms frames | Buzz/repetition and hard seams |
| Linear or bidirectional waveform interpolation | Phase cancellation, smearing, tremolo |
| Pitch-period extension gap fillers | Buzz/phase landing failures in tested implementations |
| LPC extrapolation | Robotic/buzzy and unstable at this loss rate |
| `solution3.md` anchored hybrid/noise/voiced v1 | Correct duration but dramatically less intelligible than Sonic |
| LPCNet causal/noncausal PLC | Poor on this 57-58% structured-loss mask; dependency not justified |
| Naive resampling | Correct duration only by lowering pitch; deep/slow voice |
| AVAudioUnitTimePitch / phase-vocoder style processing | Robotic or less intelligible |
| Project SOLA/WSOLA parameter sweeps | Many improvements, but all remained more robotic than current Sonic |
| Signalsmith Stretch | Permissive license, but lost more words/scored worse at ~2.3-2.4x |
| Rubber Band / content-aware time maps | Experiments did not establish a general win; GPL is also unsuitable for the permissive app distribution |
| Sonic quality 0/1 and tone variants | Mixed archive results; quality 1 fixed-ratio is the selected baseline |
| Dynamic within-utterance ratio | Speed/recognition instability; fixed per utterance is better |
| Stronger low-pass/EQ | Quieter or muffled, not genuinely cleaner; often removed consonants |
| Output gain changes | Cannot repair temporal loss; current output is not digitally clipped |
| Requested 5 ms HID interval | Property changes to 5 ms, actual input remains ~65 combined reports/s |
| High-rate inert/small HID output pulse | Did not raise incoming mic delivery and could consume transport capacity; removed |
| Large continuous audio carrier reports | Compete with input and made behavior worse |
| Private IOBluetooth link-policy experiments | No proven rate improvement; removed rather than shipping private/unreliable code |

## Strongest current causal model

### What is directly measured

1. The controller's microphone counter spans approximately 100 audio
   positions/s.
2. The app receives approximately 43 genuine mic packets/s.
3. Genuine gamepad reports consume another approximately 22 reports/s.
4. The combined report sequence is contiguous at approximately 65 reports/s.
5. The current AudioQueue supplies continuous output.
6. The raw and processed samples are not digitally clipped.
7. Disabling controller noise cancellation improves the sound but does not
   change the approximately 57% missing timeline.

### What is a strong inference, not yet definitively captured on air

macOS likely services this Bluetooth HID link on a roughly 15-16 ms grid
(possibly Bluetooth sniff/subrating or another host link scheduling policy).
The controller produces 10 ms audio frames faster than those service windows
and appears to flush old frames, sending its newest microphone frame when a
slot is available. The approximately 65 slots/s are shared between mic and
gamepad reports.

The same open-source DS5Dongle reference code reports about 100 mic frames/s
on a Pico W/BTstack host. This argues against an inherent 43 Hz limitation in
the DualSense microphone or Sony source profile.

This explanation fits every counter and cadence measurement, but a macOS
PacketLogger/HCI capture has still not been performed. Do not state sniff mode
as proven until such a trace shows it.

### Why Sonic still sounds robotic

The newest raw file contains 5.44 seconds of genuine snippets drawn from a
12.63-second source timeline. Sonic receives those nonadjacent snippets as one
compacted stream and expands them uniformly by about 2.32x. It has the scalar
ratio but not each packet's true counter position.

Pitch-period overlap avoids the pitch drop of resampling and sounds much
better than the failed alternatives, but it must repeat vowels, consonants,
transients, and noise. It also cannot synthesize a plosive or fricative that
fell entirely inside one of the 719 absent positions. Correct duration is not
the same as recovered information.

## Highest-value next investigations

### 1. Re-evaluate source channels and controller DSP on the Natural capture

This is the cheapest unexplored work and should happen before replacing the
entire reconstruction pipeline.

1. Extend `Tools/AudioLab/opus_state_replay.py` (or write a small offline
   sibling) to render channel 0, channel 1, and controlled stereo mixes from
   the newest `21.32.20 Opus.bin` archive.
2. Run the exact current cleanup + Sonic ratio on each candidate—not merely
   on compacted raw audio—and compare them with the simultaneous MacBook
   reference.
3. Listen and run the same recognizer. Prior channel-0 evidence came from the
   Sony processed source; Natural mode may alter the two lane characteristics.
4. If one channel is cleaner, make it selectable for one live A/B build before
   hard-coding it.
5. Run a one-variable live profile test with beamforming off:
   `AudioControl=0x01`, `AudioControl2=0x00`, versus the current `0x01/0x08`.
   This will determine whether the residual controller-side coloration comes
   from beamforming. Keep echo/noise cancellation off in both cases.
6. Only if needed, compare gain 12 versus 24 with post-capture loudness
   matching. Earlier low gain was too quiet, so do not confuse level with
   distortion.

Archive every live candidate's Opus/counter/raw output. Use one source change
per take; otherwise subjective results cannot identify the cause.

### 2. Prove or falsify the Bluetooth scheduling hypothesis

The highest-leverage true fix is receiving the real frames instead of
reconstructing them.

1. Use Apple's PacketLogger/Bluetooth diagnostic profile to capture one Square
   session.
2. Identify the controller ACL handle and inspect Mode Change/sniff/subrating
   events and their interval.
3. Count mic-tagged 0x31 reports on air. Determine whether the missing mic
   counter values were never transmitted or were discarded inside macOS.
4. Look for a rejected additional L2CAP connection/channel, although the
   DS5Dongle evidence says the normal HID interrupt channel carries the mic.
5. If possible, run the identical arming bytes on Linux/BlueZ with `btmon` and
   measure the same controller. A near-100/s Linux result would isolate macOS
   host policy convincingly.

Transport success criteria:

```text
real mic delivery >= 90-95 frames/s
counter gaps < 5%
duplicates/backwards = 0
required reconstruction ratio near 1.0
```

Do not repeat the already-ineffective high-rate output pulse or large carrier
flood without a new transport mechanism. A shippable macOS solution must avoid
private APIs, SIP changes, kexts, or forcing users to buy proprietary software.

### 3. If transport cannot improve, propose a genuinely different reconstructor

Any new reconstruction method must first beat the current fixed-ratio Sonic
path offline. Correct duration alone is not evidence of improvement.

Promising shapes could include:

- a transient-protected duration allocator that leaves consonants close to 1x
  and pays most timing debt in stable vowels and silence;
- a substantially better counter-aware bidirectional concealment method than
  `/path/to/ephemeral-research/anchored_reconstruct_v1.py`, with explicit phase/energy landing
  tests and fresh-noise handling for unvoiced gaps;
- a small, permissively licensed speech PLC/resynthesis model trained on this
  exact quasi-periodic 10-20 ms hole distribution with short lookahead;
- a hybrid that uses a neural/classical filler only for short holes and falls
  back to bounded Sonic expansion elsewhere.

Constraints for neural work:

- real-time on Apple Silicon;
- privacy-preserving and local;
- redistributable code and model license;
- manageable app size;
- no confident hallucination of words for a dictation product;
- measurable wins on the archived real loss masks, not only synthetic packet
  loss benchmarks.

Evaluate at least the newest Natural pair plus four older archives. A candidate
must improve listening quality and word recognition without regressing older
takes. Objective perceptual metrics can assist, but DNSMOS alone has selected
candidates that lost more words before.

## Acceptance criteria

The remaining task is complete only when a fresh live Bluetooth take meets all
of these, not when an offline clip merely sounds different:

1. The user considers the voice natural and clean, not robotic, airy,
   fast-forwarded, slowed, gated, or distorted.
2. It is reasonably close to the simultaneous MacBook Air recording. The
   controller hardware will have a different frequency response, but obvious
   temporal artifacts should be absent.
3. Spoken words are preserved. A repeatable recognizer transcript should be
   nearly identical to the MacBook reference, with no recurring phoneme loss.
4. Pitch and sentence speed are natural.
5. The first word is not clipped.
6. No output underruns, insertion gaps, clicks, or digital clipping occur.
7. Triangle dictation starts and stops on press/release.
8. Square recording/playback, controller lights, mute toggle, touchpad, button
   mappings, and Bluetooth input continue working.
9. Game Center does not open.
10. The MacBook's normal microphone/default-input behavior remains intact
    after a session and after app restart.
11. The solution is self-contained and open-source distributable; no MetaVoice
    or assumed third-party virtual cable.

## Reproduction protocol

1. Connect the DualSense through Bluetooth only; disconnect USB-C.
2. Launch `/path/to/agent-remote/dist/DualSense Bridge.app`.
3. Confirm **Bluetooth Mic Sound -> Natural (Recommended)** in the menubar.
4. Start **MacBook Mic Reference Recording** from the menubar.
5. Press Square once to start the controller recording.
6. Wait for the active blue/sky-blue controller recording indication, then
   speak the same fixed 10-15 second sentence into both microphones.
7. Press Square again. The controller WAV is saved and played automatically.
8. Stop the MacBook reference recorder.
9. Compare the newest timestamped pair in
   `/path/to/private-audio-fixtures/`.
10. Inspect the matching Raw WAV, Counters, and Opus archive under
    `Diagnostics/`, plus `~/Library/Logs/Agent Remote/Agent Remote.log`.

## Important files

Core live path:

- `Sources/DualSenseBridge/DualSenseBluetoothEnhancedModeEnabler.swift`
- `Sources/DualSenseBridgeCore/DualSenseBluetoothAudioProtocol.swift`
- `Sources/DualSenseBridge/BluetoothOpusDecoder.swift`
- `Sources/DualSenseBridge/DualSenseAudioInputManager.swift`
- `Sources/DualSenseBridge/VirtualMicrophonePCMOutput.swift`
- `Sources/DualSenseBridgeCore/DualSenseSonicSpeechTimeStretcher.swift`
- `Sources/DualSenseBridgeCore/DualSenseSpeechCleanupFilter.swift`
- `Sources/DualSenseBridgeCore/DualSenseAdaptiveSpeechTiming.swift`
- `Sources/CSonic/sonic.c`
- `Driver/DualSenseBridgeMic.c`

Settings and UX:

- `Sources/DualSenseBridge/BridgeSettings.swift`
- `Sources/DualSenseBridge/StatusMenuController.swift`
- `Sources/DualSenseBridge/ControllerBridge.swift`
- `Sources/DualSenseBridge/main.swift`

Reproducible offline tools kept in the repository:

- `Tools/AudioLab/opus_state_replay.py`
- `Tools/AudioLab/score_sonic_quality.py`

Useful but temporary analysis artifacts (may disappear after a reboot/cleanup):

- `/path/to/ephemeral-research/make_sonic_archive_replays.py`
- `/path/to/ephemeral-research/dualsense-sonic-archive-replays/`
- `/path/to/ephemeral-research/anchored_reconstruct_v1.py`
- `/path/to/ephemeral-research/anchored-v1/`
- `/path/to/ephemeral-research/decode_dualsense_channels.py`
- `/path/to/ephemeral-research/dualsense-july22-channels/`
- `/path/to/ephemeral-research/make_content_aware_timemaps.py`
- `/path/to/ephemeral-research/july22-content-candidates/`

The directory is currently **not a Git repository**. Preserve files carefully
and do not assume `git restore` can recover an experiment.

## Build and verification

Run the tests with compiler caches inside the workspace:

```sh
env \
  CLANG_MODULE_CACHE_PATH=/path/to/agent-remote/.build/ModuleCache \
  SWIFTPM_MODULECACHE_OVERRIDE=/path/to/agent-remote/.build/ModuleCache \
  swift test \
    --disable-sandbox \
    --scratch-path .build \
    -Xswiftc -module-cache-path \
    -Xswiftc .build/ModuleCache
```

At the time of this handoff, all 62 tests pass.

Package and sign with:

```sh
./scripts/package-app.sh
```

The production bundle is:

`/path/to/agent-remote/dist/DualSense Bridge.app`

Packaging uses the existing project-local signing identity when available so
macOS retains Accessibility approval. After changing the audio path, package,
quit the old `DualSenseBridge` process, launch the new bundle, and confirm the
startup/capture log before asking the user to test. A debug build alone is not
the installed application.

## Do not regress or repeat without a new reason

- Do not ask the user to toggle Accessibility repeatedly; it is already
  allowed and mouse/keyboard injection works.
- Do not reinstall or depend on MetaVoice.
- Do not strand **DualSense Bridge Mic** as the system default input.
- Do not route proprietary audio-tagged reports through GameController; that
  previously launched Game Center and broke ordinary inputs.
- Do not send an unproven microphone-disable transition after each take; this
  firmware's Bluetooth stream is sticky and bad transitions prevented later
  re-arming.
- Do not overwrite audio control fields with LED reports.
- Do not advance the production Opus decoder through all missing positions.
- Do not fill every missing position with ordinary Opus PLC.
- Do not use resampling to get the right duration.
- Do not make the 5 kHz low-pass stronger and mistake muffling for fidelity.
- Do not tune only one recording; replay several archives and then obtain a
  fresh live test.
- Do not claim the problem is solved based only on ASR or DNSMOS. The user's
  direct listening comparison is the final quality gate.

## What a useful new-agent proposal should contain

A proposed fix should explicitly answer:

1. Which measured mechanism is it addressing: controller DSP, Opus channel
   selection, macOS transport scheduling, or reconstruction?
2. What evidence distinguishes that mechanism from the others?
3. How will it be tested first on the exact newest archive without risking the
   working live path?
4. What baseline files and metrics will it compare against?
5. Why is it materially different from the failed approaches above?
6. Is it real-time, private, and legally redistributable?
7. What live result would falsify the idea?

The ideal result is a way to make substantially more genuine frames arrive.
If macOS prevents that, the next best proposal must confront the information
loss honestly and demonstrate a natural-sounding improvement over the current
Sonic build—not merely another correctly timed synthetic waveform.
