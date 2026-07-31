# DualSense Bluetooth microphone on macOS: fourth solution

Date: 22 July 2026

This is the round-4 response to `problem4.md`. It reports completed work, not
proposals: the three highest-value investigations from the handoff were run,
their results are reproducible from tools now committed to the repository, the
one change the evidence justified is implemented, packaged, signed, and
installed, and the decisive next measurement is specified step by step.

The honest headline: the reconstruction pipeline is no longer idea-bound, it
is evidence-bound. Every tested change to what the time stretcher hears —
including both "promising shapes" that `problem4.md` suggested — lost words
against the current build across fourteen archived takes. The channel-lane
question is now answered with data. What still separates this microphone from
the MacBook reference is the transport: 43 real frames arrive per second out
of 100. The two moves that can still close that gap are written below, and one
of them ships in this build as a menu item.

## Executive summary of round 4

1. **The source/channel question is answered.** On the newest Natural-profile
   capture and thirteen older archives, channel 0 through the identical live
   pipeline scores best (word error 0.235). The 50/50 lane mix is worse
   (0.259) and channel 1 — the presumed ASR lane — is worst (0.288). Under
   the Natural profile the two Opus lanes are near-duplicates (correlation
   0.95, zero lag, similar level), so no lane selection change can produce a
   meaningful win. The live decoder correctly emits channel 0 and its comment
   now records the re-validation.

2. **Both reconstruction shapes proposed in `problem4.md` were implemented
   and reproducibly rejected.** A counter-aware seam aligner (phase-matched,
   crossfaded joins at every hole junction) scored 0.379 — far worse than the
   0.235 baseline — because discarding even one to three milliseconds of real
   samples at roughly four hundred junctions costs more than phase continuity
   buys. A transient-protected duration allocator (counter-paced Sonic with
   per-island ratios: onsets held near 1x, silence overpaying, a leaky debt
   controller spreading the balance) scored 0.272 in its conservative tuning
   and 0.301 in its aggressive tuning. Uniform fixed-ratio Sonic remains the
   measured optimum of every time-domain approach tried across four rounds.

3. **The one-variable beamforming experiment is shipped.** The menubar's
   Bluetooth Mic Sound menu now has a third option, **Natural, No Beamforming
   (Test)** (`AudioControl 0x01 / AudioControl2 0x00`), exactly as the
   handoff prescribed. The default remains Natural. All 62 tests pass; the
   packaged, signed bundle is installed and its startup log is verified.

4. **The decisive transport measurement is fully specified** (PacketLogger
   section below). It requires about ten interactive minutes because someone
   must press Square and speak while the capture runs; nothing about it is
   blocked on code.

## The offline study

### Tools (now part of the repository)

- `Tools/AudioLab/render_reconstruction_candidates.py` — decodes any archived
  `... Opus.bin` with the exact live decoder behavior (stereo decode, skip
  holes, never advance state) and renders seven candidates per take with the
  exact live cleanup and finishing filters and vendored Sonic:
  `base-ch0`, `base-ch1`, `base-mid`, `seam-ch0`, `alloc1-ch0`, `alloc2-ch0`,
  `allocseam1-ch0`. Every candidate lands at the archive's exact counter
  duration, so scores reflect reconstruction quality, not speed error.
- `Tools/AudioLab/score_candidates.py` — transcribes each candidate and the
  nearest-in-time MacBook reference with the same repeatable recognizer used
  in every round (Faster Whisper `tiny.en`, int8, beam 5, no VAD) and reports
  word edit distances per take and in total.

Rerun everything with:

```sh
cd Tools/AudioLab
./build-sonic-library.sh
python3 render_reconstruction_candidates.py \
  "/path/to/private-audio-fixtures/Diagnostics/"*" Opus.bin" \
  --output /path/to/rendered-candidates
uv run --no-project \
  --with faster-whisper python3 score_candidates.py \
  /path/to/rendered-candidates /path/to/private-audio-fixtures
```

The tools find Homebrew Opus on Apple silicon or Intel automatically. The Sonic
library defaults to `.build/audio-lab/libsonic.dylib`, compiled from the same
vendored source as the app by `build-sonic-library.sh`.

### Validation before comparison

- On the newest archive, the tool's channel-0 decode reproduces the app's
  archived `Raw.wav` with **maxError = 0** — the offline chain and the live
  decoder are sample-identical at the decode stage.
- `base-ch0` re-renders the live pipeline (cleanup → Sonic quality 1, one
  fixed ratio → finishing shelf). A ratio A/B on the newest take confirmed
  the live session's learned 2.3172 and the exact counter 2.3217 transcribe
  identically (7/28 edits each), so session-ratio learning is not a quality
  bottleneck.

### Results: word edits versus the simultaneous MacBook transcript

Total across all fourteen archived takes (459 reference words; lower is
better; `live-app` is the WAV each historical build actually saved, so its
older rows include older pipelines):

| Candidate | Total edits | Rate |
|---|---:|---:|
| **base-ch0 — current live pipeline** | **108** | **0.235** |
| base-mid — 50/50 lane mix | 119 | 0.259 |
| alloc2 — conservative transient-protected allocator | 125 | 0.272 |
| live-app — shipped recordings, mixed build eras | 130 | 0.283 |
| base-ch1 — channel 1 (ASR lane) | 132 | 0.288 |
| alloc1 — transient-protected allocator | 138 | 0.301 |
| allocseam1 — allocator plus seam alignment | 172 | 0.375 |
| seam-ch0 — phase-aligned crossfaded hole junctions | 174 | 0.379 |

Per-take (edits; reference word count in the second column):

| Take | words | live-app | base-ch0 | ch1 | mid | seam | alloc1 | alloc2 | allocseam1 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 07-19 20.01.17 | 35 | 9 | 12 | 9 | 8 | 8 | 9 | 9 | 6 |
| 07-19 22.18.44 | 28 | 10 | 8 | 15 | 13 | 20 | 9 | 7 | 17 |
| 07-19 23.34.46 | 31 | 4 | 5 | 5 | 5 | 6 | 5 | 5 | 5 |
| 07-20 13.20.01 | 31 | 3 | 7 | 5 | 6 | 8 | 7 | 8 | 10 |
| 07-20 15.30.42 | 48 | 10 | 10 | 11 | 12 | 19 | 13 | 11 | 15 |
| 07-20 16.37.11 | 32 | 5 | 4 | 7 | 6 | 3 | 6 | 3 | 7 |
| 07-21 11.11.46 | 27 | 27 | 13 | 14 | 14 | 17 | 21 | 19 | 18 |
| 07-21 12.01.30 | 42 | 12 | 12 | 12 | 14 | 20 | 16 | 15 | 20 |
| 07-21 12.59.54 | 27 | 8 | 6 | 12 | 9 | 20 | 8 | 8 | 20 |
| 07-21 16.17.30 | 29 | 6 | 5 | 7 | 5 | 10 | 3 | 5 | 10 |
| 07-21 21.40.34 | 31 | 1 | 0 | 3 | 0 | 5 | 1 | 4 | 4 |
| 07-22 14.03.39 | 21 | 13 | 6 | 6 | 6 | 10 | 12 | 5 | 9 |
| 07-22 17.42.52 | 49 | 11 | 13 | 17 | 12 | 14 | 17 | 13 | 15 |
| 07-22 21.32.20 | 28 | 11 | 7 | 9 | 9 | 14 | 11 | 13 | 16 |

Individual takes swing by a few edits in both directions — the same
archive-to-archive variance every earlier sweep showed — but no candidate
beats the baseline in aggregate, and the two structural changes lose on
almost every take. The rendered WAVs for every take and candidate are under
`/path/to/ephemeral-research/dualsense-round4-candidates/` (ephemeral; regenerate with the
commands above), so the aggregate can also be checked by ear, which remains
the project's final gate.

### What each result means

**Channel lanes (Natural profile).** Measured on the newest archive: the two
decoded lanes correlate at 0.9498 with best alignment at lag 0 and nearly
equal RMS (1640 versus 1710). Under `0x01/0x08` the controller is not sending
one processed and one raw lane; it is sending two nearly identical beam
outputs. Channel 0 remains the correct choice, now confirmed on the profile
the app actually uses. The mid mix's small SNR gain does not survive the
recognizer. `BluetoothOpusDecoder.swift`'s channel comment records this.

**Seam alignment failed for an instructive reason.** The idea assumed hard
phase joins at hole junctions were a major artifact source. But Sonic's
pitch-period blending already smears each junction over a period, and the
newest take has 408 junctions: aligning each one discards up to 2 ms of
genuine samples (shift search) and blends 1 ms more (crossfade). At 43
percent survival, real samples are the scarcest resource in this system.
Trading them for phase continuity is a net loss — consistent with round-3's
finding that every hole-filling variant that touched real material regressed.

**The transient-protected allocator failed more gently, and its failure
brackets the design space.** The conservative tuning (onsets capped at 1.3x,
sustained fricatives at 2.0x, debt spread over 25 islands) came closest of
any structural change (0.272) yet still lost to uniform stretching (0.235).
Two mechanisms explain it. First, Sonic's period estimation benefits from a
steady rate; every rate change perturbs the overlap positions across several
periods. Second, counter-paced correction concentrates timing debt onto the
islands after long holes, exactly where the signal is least reliable. The
live rule — one fixed ratio per utterance, learned between sessions — is not
a placeholder; it is load-bearing, and `problem4.md`'s failed-approaches
table should now list both shapes with these numbers.

**Live-path parity.** Offline `base-ch0` scored 7/28 on the newest take
versus 11/28 for the WAV the live app saved. The ratio A/B eliminated
session-ratio learning as the cause; the deactivation path already streams
800 ms of release silence through Sonic, so no tail is being truncated. The
residual difference concentrates at the lead-in/tail silence the live file
includes and is within this recognizer's jitter. No live defect is indicated.

## What changed in the application

One capability, zero changes to the audio pipeline:

- `Sources/DualSenseBridge/DualSenseBluetoothEnhancedModeEnabler.swift` —
  new capture profile **Natural internal array without beamforming**
  (`0x01/0x00`) and a three-state `MicrophoneCapturePreset` API replacing the
  two-state boolean. A change during a take still deliberately applies to the
  next take.
- `Sources/DualSenseBridge/BridgeSettings.swift` — third
  `BluetoothMicrophoneSound` case, **Natural, No Beamforming (Test)**;
  persisted like the others; default remains **Natural (Recommended)**.
- `Sources/DualSenseBridge/DualSenseAudioInputManager.swift`,
  `StatusMenuController.swift`, `main.swift` — plumbing for the new preset.
- `Sources/DualSenseBridge/BluetoothOpusDecoder.swift` — comment updated
  with the Natural-profile channel re-validation.

Verification performed:

- Full suite passes: **62 tests, 2 suites** via the documented
  `swift test` invocation.
- `./scripts/package-app.sh` rebuilt and signed
  `dist/DualSense Bridge.app` with the existing local identity (Accessibility
  approval retained; log shows `accessibilityTrusted=true` on first launch).
- The old process was quit, the new bundle launched, and the startup log
  confirmed: preferred profile *Natural internal array*, Opus decoder
  prepared in 0.042 s, virtual microphone prepared (status 0), learned Sonic
  ratio 2.3217 carried over. The controller was asleep at verification time;
  it re-pairs on wake as usual.

## The live A/B the user should run first (five minutes)

This is the cheapest remaining experiment that can change the sound, and it
is one variable by construction — echo and noise cancellation stay off in
both arms:

1. Bluetooth-only controller, launch the installed app.
2. Menubar → **Bluetooth Mic Sound → Natural (Recommended)**. Record one
   Square take of the standard sentence with the MacBook reference running.
3. Menubar → **Bluetooth Mic Sound → Natural, No Beamforming (Test)**. The
   log will print `preferred capture profile set to: Natural internal array
   without beamforming`. Record a second take of the same sentence.
4. Compare the pair by ear and, if useful, by the scoring tool. Each take's
   Opus/Counters/Raw archive lands in `Diagnostics/` as always, so the
   result is preserved either way.

Interpretation: if the no-beamforming take is audibly cleaner, the residual
coloration was created controller-side before Opus encoding, and the default
should flip in a follow-up build. If it is equal or worse, controller DSP is
exonerated and the remaining robotic character is fully attributable to the
57 percent structured loss — strengthening the transport case below. Either
outcome is progress; neither risks the working path.

## The decisive transport measurement (requires the user)

Nothing in four rounds has moved the ~43 real frames/s over this link, and
`problem4.md` is right that receiving real frames beats reconstructing them.
The measurement that settles *why* only ~65 report slots/s exist:

1. **Install PacketLogger.** Xcode 16 is present but PacketLogger is not; it
   ships in "Additional Tools for Xcode" from
   `developer.apple.com/download/all/` (match the installed Xcode version).
2. **Capture one Square session.** Start a new trace in PacketLogger, then
   record a normal 10–15 second take, then stop the trace. Controller
   address: `7C:66:EF:64:4B:89`.
3. **Read three things from the trace:**
   - the ACL connection handle for that address, from the Connection
     Complete or an existing-connection packet;
   - any **Mode Change** events on that handle: sniff versus active, and the
     interval in slots (0.625 ms each). The prediction from the observed
     cadence is sniff (or an equivalent service grid) at roughly 24–25 slots
     (15.0–15.6 ms). Also look for **Sniff Subrating** events;
   - the count of inbound HID interrupt packets carrying mic-tagged 0x31
     reports during ten seconds of speech. If ~43/s appear on air, the
     controller genuinely transmits only what the grid allows (host-side
     scheduling proven). If ~100/s appear on air but ~43/s reached the app,
     macOS is dropping them after reception (a different, likely
     reportable bug).
4. **Optional cross-check** that isolates macOS policy in one afternoon:
   boot any Linux live USB with BlueZ, pair the controller, replay the same
   arming bytes (documented in
   `Sources/DualSenseBridgeCore/DualSenseBluetoothAudioProtocol.swift`), and
   count 0x31 mic reports with `btmon`. The DS5Dongle reference on BTstack —
   whose default link policy rejects sniff — already receives ~100/s with
   identical arming, which is why the host-policy explanation is favored.

Success criteria are unchanged from `problem4.md`: real delivery at 90–95
frames/s or better, counter gaps under 5 percent, no duplicates, required
ratio near 1.0.

What the outcomes would mean:

- **Sniff confirmed** → the fix is host link policy, which an unprivileged,
  distributable app cannot set on macOS. File Apple feedback with the trace
  (bluetoothd offers no supported per-link QoS control to applications; the
  HID `ReportInterval` property is accepted but has no effect on this link —
  both already demonstrated by this project). Until macOS changes, Bluetooth
  fidelity is bounded by reconstruction from ~43 percent of frames, and the
  shipped Sonic path is the measured best of that class.
- **Not sniff but a fixed ACL service grid** → same conclusion, different
  mechanism name; the feedback report still carries the evidence.
- **Frames on air but dropped in the stack** → a concrete macOS bug with a
  concrete trace; that would be the single highest-value discovery available
  and would justify revisiting IOKit-side mitigation.

Non-goals remain binding: no private APIs, no SIP changes, no kexts, no
required third-party purchases. For completeness, two supported paths already
deliver 100 percent of frames today: USB-C (the controller becomes a normal
Core Audio microphone) and, for the adventurous, the open-source DS5Dongle
firmware on a $10 Pico W. Both are documented alternatives, not the solution.

## If transport is confirmed immovable

The only class of reconstruction not yet falsified is a learned concealment
model trained on this exact quasi-periodic 10–20 ms loss mask. Round 4's
contribution to that future decision is a hard, reproducible gate: any such
model must beat **108/459** on these fourteen archives through
`score_candidates.py`, listen better on the newest pair, run in real time on
Apple Silicon, and carry a redistributable license. The generic pretrained
route was already rejected in round 3 (LPCNet, poor on this mask), so this
means training, which should only be undertaken if the PacketLogger result
closes the transport door and the user still wants Bluetooth-only perfection.
`problem4.md`'s constraint stands: for a dictation product, a model that
hallucinates confident words is worse than one that sounds slightly robotic.

## Acceptance criteria status

| # | Criterion | Status |
|---|---|---|
| 1 | Natural, clean voice | Open — bounded by 43/100 transport; best measured pipeline shipped; beamforming A/B may still improve it |
| 2 | Close to simultaneous MacBook capture | Open — same bound |
| 3 | Words preserved, near-identical transcript | Improved but open; 0.235 versus 0.03–0.05 for the MacBook reference through the same recognizer |
| 4 | Natural pitch and speed | Met (counter-exact duration, pitch-preserving expansion; user-confirmed speed in round 3) |
| 5 | First word not clipped | Met (prewarm + 48-frame calibration; verified again in newest take) |
| 6 | No underruns/gaps/clipping | Met (100.0% duty, 0 underruns, no digital clipping in newest take) |
| 7 | Triangle dictation press/release | Met, unchanged |
| 8 | Square record/playback, lights, mute, inputs | Met, unchanged; new menu item verified in build |
| 9 | No Game Center | Met, unchanged |
| 10 | Default input restored | Met, unchanged |
| 11 | Self-contained, distributable | Met — bundled libopus/driver, vendored Apache-2.0 Sonic, no MetaVoice |

Criteria 1–3 are the transport-bound remainder. They move only with more real
frames (PacketLogger path) or, failing that, with the trained-concealment
route behind the 108-edit gate — plus whatever the beamforming A/B reveals
about controller-side coloration.

## Do not regress or repeat (additions to the round-4 list)

- Do not re-try discard-based seam alignment at hole junctions (any variant
  that shortens real islands): 174/459 versus 108/459 baseline.
- Do not re-try per-island or counter-paced ratio modulation around Sonic
  (transient-protected or otherwise) without a mechanism that avoids both
  measured failure causes: 125–138/459 versus 108/459.
- Do not switch the decoder to channel 1 or a lane mix on the Natural
  profile: 132 and 119 versus 108.
- Do not treat `live-app` transcription deltas at the take level as pipeline
  regressions before checking lead/tail silence and recognizer jitter; the
  ratio A/B method above is the cheap way to isolate real causes.
- Everything in `problem4.md`'s existing list still applies, including: do
  not claim success from ASR or DNSMOS alone — the user's ear is the gate.

## Build, verify, reproduce

```sh
# tests (62 expected to pass)
env CLANG_MODULE_CACHE_PATH=/path/to/agent-remote/.build/ModuleCache \
    SWIFTPM_MODULECACHE_OVERRIDE=/path/to/agent-remote/.build/ModuleCache \
    swift test --disable-sandbox --scratch-path .build \
    -Xswiftc -module-cache-path -Xswiftc .build/ModuleCache

# package + sign the installed bundle
./scripts/package-app.sh

# offline study (render + score), as given in "The offline study"
```

Live reproduction protocol is unchanged from `problem4.md`. The directory is
still not a Git repository; preserve files accordingly.

## Files added or changed in round 4

Added:

- `Tools/AudioLab/render_reconstruction_candidates.py`
- `Tools/AudioLab/score_candidates.py`
- `solution4.md` (this file)

Changed:

- `Sources/DualSenseBridge/DualSenseBluetoothEnhancedModeEnabler.swift`
- `Sources/DualSenseBridge/BridgeSettings.swift`
- `Sources/DualSenseBridge/DualSenseAudioInputManager.swift`
- `Sources/DualSenseBridge/StatusMenuController.swift`
- `Sources/DualSenseBridge/main.swift`
- `Sources/DualSenseBridge/BluetoothOpusDecoder.swift` (comment only)

Rebuilt and installed:

- `dist/DualSense Bridge.app` (running; startup log verified)

## The seven questions, answered

1. **Mechanism addressed:** all four were touched — controller DSP (shipped
   beamforming A/B), Opus channel selection (answered: keep channel 0),
   reconstruction (two shapes tested and rejected), transport (decisive
   capture specified).
2. **Distinguishing evidence:** the 14-archive score table; the lane
   correlation measurement; the counter/cadence data carried forward from
   rounds 1–3.
3. **Tested without risking the live path:** every candidate was rendered
   offline from archives before any live change; the only live change is an
   additive, default-off menu option.
4. **Baselines and metrics:** `base-ch0` re-derivation of the live pipeline
   (validated sample-exact at decode, ratio-A/B at output) and word edit
   distance against paired MacBook transcripts, all rerunnable.
5. **Difference from failed approaches:** the seam aligner and allocator were
   the two shapes `problem4.md` itself proposed as promising; they are now
   measured, not speculative, and join the failed list with numbers.
6. **Real-time, private, redistributable:** nothing shipped adds a
   dependency; the tools are offline-only; Sonic remains Apache-2.0.
7. **What would falsify the current position:** a PacketLogger trace showing
   ~100 mic frames/s on air (host drop → fixable bug), a Linux `btmon` count
   near 100/s (macOS policy → Apple feedback with evidence), or any candidate
   beating 108/459 through the committed scorer and the user's ear.
