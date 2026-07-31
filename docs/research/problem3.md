# DualSense Bluetooth microphone on macOS: third engineering handoff

Date: 20 July 2026

This document is the current, self-contained handoff for the remaining
DualSense Bluetooth microphone problem. `problem.md`, `solution.md`,
`problem2.md`, and `solution2.md` in this repository contain the earlier
investigation. They are useful history, but a new investigator should be able
to start with this file.

## Executive summary

The app is now functionally complete enough to use:

- A Bluetooth DualSense is read through raw IOKit HID without Game Center
  taking over the controller.
- Touchpad pointer movement, scrolling, taps, clicks, and face-button mappings
  work.
- Triangle can hold Command-O for Codex dictation and releases it correctly.
- The physical controller microphone can be unmuted and its mute button works.
- Real controller microphone Opus packets reach the Mac and decode correctly.
- A project-owned Core Audio virtual microphone routes that PCM to Codex and
  other applications. MetaVoice is not required.
- Square records exactly what the virtual microphone emits, saves it, and
  plays it back. A paired MacBook microphone recorder is available in the
  menubar for comparisons.
- Startup is prewarmed, so the first word is no longer normally clipped.

The unresolved problem is audio fidelity over Bluetooth. The voice is now
understandable and at approximately the correct speed, but it remains robotic,
distorted, and clearly worse than the MacBook Air microphone.

The strongest evidence says this is not an EQ, gain, mute, virtual-driver,
Opus-decoder, or ordinary AudioQueue problem. The controller generates a
nominal 100 ten-millisecond audio-frame positions per second, but only about
41-44 real Opus frames per second reach the app. In the newest capture, 861
received frames represented 2,071 counter positions. About 58.4% of the source
timeline was absent. The current code stretches and waveform-aligns the 41.6%
that survived. It cannot recreate phonetic information that was never
delivered, which is the likely source of the remaining robotic quality and
word errors.

The next useful solution therefore needs to do one of two things:

1. Find a Bluetooth/HID control or transport mode that makes substantially
   more real microphone frames reach macOS, ideally close to 100 per second.
2. Replace the current uniform SOLA reconstruction with a materially better
   loss-aware speech reconstruction method that remains real-time,
   privacy-preserving, redistributable, and open-source compatible.

Another round of small EQ or global time-stretch parameter changes is unlikely
to produce MacBook-quality speech.

## User-visible failure

The newest canonical comparison is:

- MacBook reference:
  `/path/to/private-audio-fixtures/MacBook Mic Reference 2026-07-20 15.30.19.wav`
- Processed controller recording:
  `/path/to/private-audio-fixtures/DualSense Mic 2026-07-20 15.30.42.wav`
- Untouched decoded controller frames:
  `/path/to/private-audio-fixtures/Diagnostics/DualSense Mic 2026-07-20 15.30.42 Raw.wav`
- Controller audio counters:
  `/path/to/private-audio-fixtures/Diagnostics/DualSense Mic 2026-07-20 15.30.42 Counters.txt`
- Original received Opus packets:
  `/path/to/private-audio-fixtures/Diagnostics/DualSense Mic 2026-07-20 15.30.42 Opus.bin`

The spoken reference was approximately:

> We are still continuing, and that will show us how well this works, and if
> it works, then that is great. We still have to see if it works or not,
> because that's the most important part of this. So will it work? Let us find
> out.

A local `tiny.en` Faster Whisper check produced the following. This is not the
same recognizer Codex necessarily uses, but it is a repeatable intelligibility
check.

MacBook recording:

> We are still continuing and that will show us how well this works and if it
> works then that is great. We still have to see if it works or not because
> that's the most important part of this. So will it work? Let us find out.

Processed DualSense recording:

> We are still continuing and it will show us how well this works and it works
> then that is great. We still have to see if it works because that's almost
> important part of this. So, we had worked on a spin out.

The controller output loses or changes meaningful words even though its
duration is now plausible. Subjectively, the user reports that the new build
is still not perfect and remains more robotic/distorted than the MacBook
reference.

## Newest transport evidence

The relevant log is `~/Library/Logs/Agent Remote/Agent Remote.log`. The newest capture reported:

```text
mic input tap: duration=20.78s, records=1319, truncated=false
mic input tap classes: mic=861 (41.4/s), gamepad=458 (22.0/s), other=0 (0.0/s)
mic input tap mic counter: samples=861,
  deltas=[+1×210, +2×206, +3×396, +4×18, +5×18, +6×3],
  missed=1210, duplicates=0, backwards=0,
  received=41.5/s, estimatedGenerated=99.8/s
mic input tap transport nibble (all 0x31):
  samples=1319, deltas=[+1×1318], missed=0, duplicates=0,
  backwards=0, received=63.4/s, estimatedGenerated=63.4/s
mic input tap mic inter-arrival:
  p50=29.6ms p95=31.1ms min=14.2ms max=90.3ms mean=24.1ms
  modal=[15ms×385, 30ms×376, 31ms×27]
Bluetooth microphone audio summary:
  decoded=861, nonSilent=824, decoderStateAdvances=0,
  jitterDrops=0, maximumPeak=25962
virtual mic final adaptive timing:
  received=861, generated=2071, ratio=2.4053
virtual mic output continuity:
  signal=973200, gap=6480, duty=99.3%, underruns=1,
  totalGap=135.0ms, averageGap=135.0ms
```

The archived counter sequence gives the full distribution:

```text
received=861
generated=2071
required expansion ratio=2.405343
counter deltas:
  +1 × 210
  +2 × 206
  +3 × 396
  +4 × 18
  +5 × 18
  +6 × 3
  +7 × 1
  +8 × 1
  +9 × 6
  +11 × 1
duplicates=0
backwards=0
```

Important interpretation:

- Each received packet contains one genuine 480-sample, 48 kHz mono Opus
  frame: 10 ms of audio.
- 861 received frames contain only 8.61 seconds of genuine decoded PCM.
- Their controller counter spans 2,071 ten-millisecond positions, or 20.71
  seconds.
- Therefore 1,210 of 2,071 positions, approximately 58.4%, have no received
  real audio frame.
- The counter advances cleanly and has no duplicate or backward packets.
- The combined Bluetooth report transport sequence is completely contiguous
  at about 63.4 reports/s. Mic reports consume about 41.4/s and gamepad reports
  about 22.0/s. This makes random host callback loss less likely. A strong
  current hypothesis is that the controller/HID schedule selects only part of
  the internally generated mic stream for transmission in this mode.
- The AudioQueue delivered 99.3% signal duty. One 135 ms underrun can create a
  local dropout, but it cannot explain the persistent robotic timbre across
  the entire take. Several prior takes had 100% output continuity and still
  sounded distorted.

## Signal measurements for the newest pair

These measurements use active-frame selection, so they are guides rather than
a perfectly level-matched laboratory comparison.

| Measurement | MacBook | Processed DualSense | Raw received frames |
|---|---:|---:|---:|
| File duration | 28.768 s | 21.230 s | 8.610 s |
| Active RMS | -38.25 dBFS | -21.89 dBFS | -22.09 dBFS |
| Peak | -20.88 dBFS | -2.78 dBFS | -2.02 dBFS |
| Clipped samples | 0 | 0 | 0 |
| 99.9th percentile first derivative | 0.00787 | 0.03372 | 0.08992 |
| Median periodicity | 0.405 | 0.508 | 0.465 |

The DualSense take is much hotter because microphone position and analog gain
differ, but it is not digitally clipped. Lowering output gain alone will not
remove the temporal distortion. The much larger derivative statistics are
consistent with a waveform assembled from sparse, noncontiguous source
segments.

Active-band energy percentages:

| Band | MacBook | Processed DualSense | Raw received frames |
|---|---:|---:|---:|
| 70-180 Hz | 21.37% | 10.43% | 4.70% |
| 180-300 Hz | 16.01% | 25.77% | 19.45% |
| 300-500 Hz | 37.91% | 43.28% | 46.66% |
| 500-1000 Hz | 22.46% | 18.79% | 25.71% |
| 1-2 kHz | 1.36% | 1.54% | 1.79% |
| 2-4 kHz | 0.42% | 0.13% | 0.23% |
| 4-8 kHz | 0.42% | 0.06% | 0.99% |

The current filtering deliberately removes high-frequency discontinuity
energy. The residual mismatch is not a simple missing treble shelf; opening
the low-pass filter in earlier experiments restored more noise and edge
artifacts.

## Current application architecture

### Bluetooth HID and controls

`Sources/DualSenseBridge/DualSenseBluetoothEnhancedModeEnabler.swift`

- Seizes the raw Bluetooth DualSense HID device through IOKit.
- Enables Sony full-report mode.
- Requests a 5 ms HID report interval. The observed combined input-report rate
  remains about 63-64/s, not 200/s.
- Selects the `Sony internal CHAT/ASR` capture profile.
- Uses controller microphone gain 24.
- Sends the physical unmute reports and LED-only status reports.
- Receives mic Opus payloads and gamepad/touch reports without routing them
  through GameController during isolated Bluetooth capture.

### Opus decode and diagnostic archive

`Sources/DualSenseBridge/BluetoothOpusDecoder.swift`

`Sources/DualSenseBridge/DualSenseAudioInputManager.swift`

- Decodes each real 71-byte Opus packet as one 480-sample mono frame at 48 kHz.
- Does not advance the primary decoder state through counter gaps. Advancing
  it with large amounts of PLC corrupted subsequent real frames in earlier
  builds.
- Square diagnostics retain the untouched decoded frames, counter values, and
  exact original Opus packets for every take.

### Current cleanup and reconstruction

`Sources/DualSenseBridgeCore/DualSenseSpeechCleanupFilter.swift`

Pre-SOLA cleanup:

- 70 Hz high-pass.
- +3 dB low shelf at 180 Hz.
- Two cascaded 5 kHz low-pass biquads.

`Sources/DualSenseBridgeCore/DualSenseAdaptiveSpeechTiming.swift`

- Starts with a 2.32 expansion prior.
- Holds that prior for the first 48 received frames to avoid unstable opening
  speed.
- Then uses cumulative controller counter positions divided by received frame
  count, clamped to 1-4.

`Sources/DualSenseBridgeCore/DualSenseSpeechTimeStretcher.swift`

Current time-domain SOLA configuration:

- 1,440-sample sequence: 30 ms.
- 720-sample synthesis hop: 15 ms.
- 48-sample base search radius: ±1 ms for unvoiced/consonant regions.
- Up to 160-sample voiced search radius: ±3.33 ms.
- 70-500 Hz alignment guide.
- 30 ms pitch/periodicity context, searching approximately 80-400 Hz.
- Voiced widening only when periodicity is at least 0.66.
- Nominal-position penalty 0.03.
- Pitch-preserving time-domain overlap-add; no resampling pitch shift.

Post-SOLA tone correction:

- +2.5 dB low shelf at 180 Hz.
- Broad -2 dB peak/dip at 500 Hz, Q 1.0.

### Virtual microphone and playout

`Sources/DualSenseBridge/VirtualMicrophonePCMOutput.swift`

- Sends processed PCM through a project-owned Core Audio AudioServerPlugIn.
- Keeps the AudioQueue prepared between sessions.
- Prebuffers 14,400 samples: 300 ms.
- Resumes after 5,760 samples: 120 ms.
- Uses a 96-sample raised-cosine edge smoother only when a real output
  underrun occurs.

`Driver/DualSenseBridgeMic.c`

- Project-owned virtual microphone driver.
- This replaces the earlier MetaVoice dependency concern. End users do not
  need MetaVoice.

### Input and diagnostic UX

- Triangle defaults to Command-O and can route the DualSense mic while held.
- Circle defaults to Return.
- Square defaults to Record & Play for the controller signal.
- The menubar has a MacBook reference recorder that saves into the same
  `DualSense Mic Tests` directory.
- The app restores the prior physical input after a controller mic session and
  repairs a stranded virtual default input after an abnormal exit.

## What has already been fixed

Do not restart the investigation by assuming these are still the primary
failure:

1. **Accessibility permissions**: already granted and working for pointer,
   mouse, and keyboard event emission.
2. **Touchpad axes and lift jumps**: pointer motion, scrolling, click/tap
   behavior, and lift-state resets are implemented.
3. **Stuck Triangle/Command-O**: down and up events are separately handled;
   release no longer intentionally leaves Command-O pressed.
4. **Game Center launching**: the active Bluetooth path uses raw HID isolation
   and avoids the earlier GameController conflict.
5. **Physical mic mute**: the controller can now be unmuted; its mute toggle and
   light work.
6. **No audio at all**: real encoded Opus voice is received and decoded.
7. **MetaVoice dependency**: replaced by the bundled project-owned virtual
   microphone driver.
8. **MacBook mic left broken**: the previous physical default input is restored
   after each session and at startup if the virtual device was stranded.
9. **First-word startup clipping**: libopus and the AudioQueue are prewarmed,
   and the current buffer starts without the former 200-400 ms open delay.
10. **Fast-forwarded raw audio**: counter-derived timing reconstruction now
    produces approximately the right sentence duration and pitch.
11. **Controller LED disappearing during recording**: recording state uses
    explicit blue and finished amber LED-only reports without overwriting
    audio routing.

## Approaches already tried

### Transport and control attempts

- Multiple Sony capture-control field combinations and source profiles.
- Internal CHAT/ASR, chat-style alternatives, and control-only arming reports.
- 5 ms requested HID report interval.
- Full-report mode and continuous raw HID isolation.
- Separate mic/gamepad/combined sequence instrumentation.
- Different output keepalive/report strategies.
- Direct device seizure to prevent competing high-level consumers.

The internal CHAT/ASR profile reliably produces real voice and is the current
best working profile. None of the tested control variants has raised real mic
delivery from roughly 41-44/s to near 100/s.

### Opus PLC

Ordinary Opus packet-loss concealment was tried on the missing counter
positions. More than half the resulting stream was synthetic PLC. Speech
became barely audible or unintelligible. PLC is designed for occasional loss,
not long-term reconstruction of about 58% of all frames.

Advancing the primary decoder state through every missing frame, even when the
PLC samples were discarded, damaged the state used for later genuine packets.
The current implementation decodes only real packets on the primary decoder.

A shadow decoder and cloned-state PLC variants were also evaluated offline.
They scored and transcribed substantially worse than the SOLA path.

### Counter-position insertion and interpolation

Tried variants include:

- Repeat the previous received frame.
- Linear interpolation between adjacent received frames.
- Bidirectional frame morphing.
- Pitch-periodic extension from one or both sides.
- LPC extrapolation.
- Simple counter-aware gap insertion followed by a smaller residual stretch.
- Boundary value/slope repair around source-frame transitions.

These methods generally added buzz, tremolo, discontinuities, or smeared
consonants. Hybrid gap insertion plus mild SOLA was particularly poor on
DNSMOS and recognition compared with global SOLA.

### Neural/LPC reconstruction

An offline LPCNet packet-loss-concealment experiment was built and run against
the real counter loss mask. Both causal and noncausal outputs were poor. The
available model was not trained for this extreme, scheduler-shaped 58% loss
pattern, and the result did not justify adding a large runtime dependency.

This does not prove that all neural PLC is impossible. It does mean that a new
proposal should identify a model trained for very high burst/interleaved loss,
verify its redistribution license and model size, and beat the archived SOLA
outputs before integration.

### Resampling and system time-pitch processing

- Naive resampling fixed duration by lowering pitch, producing the original
  deep/slow voice.
- AVAudioUnitTimePitch and related spectral variants were robotic or less
  intelligible.
- Cascaded stretch stages were tested and tended to accumulate artifacts.

### External open-source stretchers

Signalsmith Stretch was downloaded and tested offline in one, two, and three
stages. It is MIT-licensed and could have been bundled, but it lost more words
and scored worse on the current data at the required approximately 2.4× ratio.
For the 13:20 archive, examples were approximately:

| Candidate | DNSMOS OVRL | DNSMOS SIG |
|---|---:|---:|
| Signalsmith one stage | 1.815 | 2.465 |
| Signalsmith two stages | 1.816 | 2.371 |
| Signalsmith three stages | 2.031 | 2.742 |
| Prior project SOLA | 2.068 | 2.739 |
| Best short-grain project SOLA | 2.355 | 3.038 |

It was therefore rejected and no new dependency was added.

Rubber Band was not adopted because its normal open-source distribution is
GPL, which is a poor fit for keeping this repository permissively licensed.

### SOLA/WSOLA exploration

Many combinations have been replayed over archived raw/counter pairs:

- Sequence lengths from approximately 20-50 ms.
- Synthesis hops from 10 ms upward.
- Narrow and wide search windows.
- Alignment-guide cutoffs around 350-900 Hz.
- Multiple nominal-position penalties.
- Fixed, cumulative, rolling, and exponential counter ratios.
- One-, two-, and three-stage cascades.
- Pitch-synchronous voiced search widening.
- Different periodicity thresholds.

Important recent results:

- A 25 ms sequence / 12.5 ms hop could score well on the newest take but lost
  more words and regressed older recordings.
- A permissive 0.30 voicing threshold improved some objective scores but
  introduced recognition errors and did not generalize as well.
- The previous 32 ms / 16 ms, ±1.7 ms base-search build retained words well but
  remained more robotic on the newest pair.
- The current 30 ms / 15 ms, ±1 ms base-search configuration was the best
  compromise found across four archived pairs.

On the controlled 13:20 archive, the selected temporal configuration plus the
500 Hz correction improved the replay approximately as follows:

| Metric | Previous installed path | Current selected path |
|---|---:|---:|
| DNSMOS OVRL | 2.068 | 2.514 |
| DNSMOS SIG | 2.739 | 3.074 |

Across four archived replays, average OVRL improved from approximately 2.391
to 2.490. The -2 dB / 500 Hz / Q1 correction improved every one of those four
replays compared with the same temporal output without the dip.

These are meaningful improvements, but the newest live 15:30 recording and
the user's listening test confirm that they did not solve the fundamental
quality gap.

### Filtering and gain

Tried filtering includes high-pass, different low-pass edges, cascaded
low-pass stages, body shelves, lower-mid dips, and output gain changes.

- Opening the low-pass restored discontinuity noise faster than useful speech
  detail.
- Stronger filtering made speech muffled or inaudible.
- Excessive low shelves made the result boomy.
- The current broad 500 Hz dip generalized across paired captures.
- Current raw peaks are below digital full scale. The newest raw peak was
  25,962, so digital clipping is not the main failure.
- Controller hardware gain is currently 24. Earlier low-gain configurations
  were barely audible. Analog-front-end distortion remains possible, but the
  latest unclipped data does not support gain as the dominant explanation.

## Strongest current root-cause model

The controller appears to create a full-rate logical audio counter but exposes
only a scheduled subset of its 10 ms Opus frames on the Bluetooth HID input
channel used by this app.

The newest combined report stream is striking:

```text
all input reports: 63.4/s, sequence perfectly contiguous
mic reports:       41.4/s
gamepad reports:   22.0/s
sum:               63.4/s
```

The mic packet counter independently estimates about 99.8 generated audio
positions per second. This suggests a deterministic Bluetooth report-budget or
interleaving problem rather than random loss after the report reaches IOKit.

The current SOLA code concatenates the surviving 10 ms snippets and expands
the compacted stream by about 2.4× while finding waveform-correlated overlap
positions. This can preserve pitch and approximate duration, but it has two
fundamental limitations:

1. It repeats surviving phonetic material instead of recovering the omitted
   material at its original counter position.
2. Uniform stretching spends too much expansion on consonants and transients,
   which produces robotic repeats and smearing. Missing consonants cannot be
   inferred reliably from unrelated neighboring samples.

The remaining problem should be treated as extreme-loss speech reconstruction
or, preferably, as a transport-mode problem—not as ordinary denoising.

## High-value directions for the next investigator

### Direction A: recover the full Bluetooth mic stream

This is the highest-value direction because any waveform reconstruction is
fundamentally limited by the missing 58%.

Questions to answer:

1. Why does the combined Bluetooth HID input stream stabilize near 63-64
   reports/s when the requested interval is 5 ms?
2. Is there a Sony report/control bit that selects a mic-priority or
   audio-only input schedule, reducing the 22 gamepad reports/s and allocating
   more report slots to mic data?
3. Is the working `CHAT/ASR` configuration intended to emit a decimated ASR
   stream rather than continuous chat audio? Is there a separate continuous
   Bluetooth voice mode that has not been replicated correctly?
4. Does the PS5 use a non-HID L2CAP channel, a second interrupt channel, or a
   different PSM for full-duplex voice that macOS does not open here?
5. Are outbound host-to-controller audio carrier reports consuming a shared
   Bluetooth budget and indirectly suppressing controller-to-host mic reports?
   Can their cadence or payload be changed without disabling the mic?
6. Can an HCI/Bluetooth packet trace prove whether the missing mic counters
   are absent over the air or discarded between the controller and IOKit?
7. Does a Linux hid-playstation, BlueZ, SDL, Chiaki, or other open-source Sony
   implementation document the full Bluetooth audio return path rather than
   only USB audio?
8. Is the counter truly incremented for every encoded 10 ms mic packet before
   HID scheduling? The observed correct final speech duration strongly
   supports this, but protocol confirmation would help.

A proposed transport change should be judged first by real received mic packet
rate and counter continuity, before listening tests or filters:

```text
target real mic delivery: at least 90-95 frames/s
target counter gaps:      under 5% in normal nearby use
target duplicates/backwards: zero
```

### Direction B: transient-protected, counter-debt reconstruction

If transport cannot be improved, the most promising unimplemented classical
algorithm is not another fixed SOLA grid. It is a local stretch allocator that
preserves unvoiced/transient material and pays the duration debt in stable
voiced or silent regions.

One possible design:

1. Maintain an exact target output cursor from the controller counter.
2. Classify each analysis region using energy, periodicity, zero-crossing rate,
   and spectral flux.
3. Give consonants/onsets/unvoiced regions a local stretch ratio near 1.0-1.4
   so they are not repeated 2.4 times.
4. Give stable voiced vowels and silence a larger local ratio, perhaps 2.7-3.2,
   to repay accumulated target-duration debt.
5. Bound the debt and smoothly interpolate analysis hops so speed does not
   pump from frame to frame.
6. For voiced regions, use actual pitch marks or epoch-synchronous overlap-add
   rather than only a wider normalized cross-correlation search.
7. Reset or constrain pitch locking at transient boundaries so the processor
   cannot remain stuck repeating one pitch grain.
8. Preserve the exact long-term counter-derived duration.

This has not yet been implemented in the project. It is more promising than
globally shortening all grains, because the short-grain experiment improved
some quality metrics but damaged word recognition.

### Direction C: exact-gap recovery with Opus FEC or a trained PLC model

The original Opus archive makes additional offline tests possible without
changing the live decoder:

- Probe whether received packets actually contain Opus in-band FEC for the
  immediately preceding missing frame. If FEC is absent, `decode_fec=1` will
  not create new information. If present, it can recover at most limited loss
  and will not by itself fill common +3 counter jumps.
- Search for a permissively licensed neural PLC model explicitly trained on
  50-60% structured/interleaved frame loss at 48 kHz or on speech-codec packet
  loss. Generic occasional-loss PLC is not sufficient.
- Validate offline on all archived raw/counter/Opus triples before adding any
  model or runtime.
- Require meaningful word-recognition gains as well as perceptual metrics.

### Direction D: determine the honest hardware limit

If the controller exposes only a decimated Bluetooth ASR stream outside a PS5
and no full-rate mode exists, then MacBook-quality live speech may be
unachievable over Bluetooth alone. In that case the product should explicitly
offer:

- High-quality USB mode using the native DualSense Core Audio microphone.
- Best-effort Bluetooth mode with a disclosed quality limitation.
- An optional small USB audio receiver/cable route if the user requires the
  controller mic and full fidelity simultaneously.

This conclusion should be made only after Direction A is exhausted with
protocol evidence.

## Experiments that should not be repeated without a new reason

- Toggling Accessibility or Microphone permission again.
- Reinstalling MetaVoice.
- Raising output gain to hide the problem.
- Globally slowing raw PCM through resampling.
- Filling every missing position with ordinary Opus PLC.
- Advancing the primary real-packet decoder through all missing counters.
- Repeating or linearly interpolating entire 10 ms frames.
- Adding a stronger low-pass filter and calling the quieter result cleaner.
- Retuning only one recording without replaying at least three older archives.
- Trusting DNSMOS alone when the recognizer loses words.

## Reproduction and comparison protocol

1. Connect the DualSense over Bluetooth only. Disconnect USB-C.
2. Launch `dist/DualSense Bridge.app`.
3. Confirm the menubar reports a connected controller and a DualSense BT mic
   route.
4. Start the MacBook reference recorder from the menubar.
5. Press Square once. Wait for the controller light to show the active blue
   recording state.
6. Speak a fixed phrase for at least 10-15 seconds with consonants, pauses, and
   a question. Keep the controller at a repeatable distance.
7. Press Square again. It should stop, save, turn amber, and play the result.
8. Stop the MacBook reference recorder.
9. Collect the five files described at the start of this document.
10. Inspect `~/Library/Logs/Agent Remote/Agent Remote.log` for:
    - received and generated frame counts;
    - mic counter delta distribution;
    - combined report rate;
    - duplicates/backwards;
    - AudioQueue duty and underruns;
    - raw decoder peak.
11. Compare words with the same local recognizer configuration. Do not judge
    only loudness or one perceptual score.

The Square recording is captured after cleanup, timing correction, finishing
EQ, AudioQueue buffering, and gap smoothing. It represents what microphone
clients receive. The `Raw.wav` diagnostic is the untouched concatenation of
the 480-sample real decoder outputs and is expected to sound fast-forwarded.

## Acceptance criteria

A real solution should satisfy all of these:

1. Bluetooth-only operation; no USB-C cable required.
2. No MetaVoice or separately installed proprietary loopback dependency.
3. No Game Center launch or GameController takeover.
4. Triangle/Command-O down and up remain correct.
5. The controller mute button and recording LEDs remain correct.
6. First spoken word is retained on the first recording after launch.
7. Output duration stays within about 1% of the controller counter timeline.
8. No deep/slow pitch shift, fast-forwarding, robotic repetition, or regular
   cutouts.
9. Fixed-phrase recognition preserves essentially the same words as the paired
   MacBook recording.
10. AudioQueue has no recurring underruns under normal nearby Bluetooth use.
11. The previous physical Mac input is restored after release or app exit.
12. New code and dependencies are redistributable in an open-source release;
    users should not need to install developer tools or extra audio software.
13. The change improves the newest archive and does not materially regress at
    least three earlier archived captures.

## Relevant repository files

Core reconstruction:

- `Sources/DualSenseBridgeCore/DualSenseSpeechTimeStretcher.swift`
- `Sources/DualSenseBridgeCore/DualSenseAdaptiveSpeechTiming.swift`
- `Sources/DualSenseBridgeCore/DualSenseSpeechCleanupFilter.swift`
- `Sources/DualSenseBridgeCore/DualSensePCMGapSmoother.swift`

Bluetooth audio and routing:

- `Sources/DualSenseBridge/DualSenseBluetoothEnhancedModeEnabler.swift`
- `Sources/DualSenseBridge/BluetoothOpusDecoder.swift`
- `Sources/DualSenseBridge/DualSenseAudioInputManager.swift`
- `Sources/DualSenseBridge/VirtualMicrophonePCMOutput.swift`
- `Sources/DualSenseBridge/ControllerBridge.swift`

Protocol and diagnostics:

- `Sources/DualSenseBridgeCore/DualSenseBluetoothAudioProtocol.swift`
- `Sources/DualSenseBridgeCore/MicrophoneInputTap.swift`
- `Sources/DualSenseBridge/DiagnosticLog.swift`

Virtual device:

- `Driver/DualSenseBridgeMic.c`
- `Sources/DualSenseBridge/BundledMicrophoneDriverManager.swift`

Tests:

- `Tests/DualSenseBridgeCoreTests/SpeechTimeStretcherTests.swift`
- `Tests/DualSenseBridgeCoreTests/SpeechCleanupFilterTests.swift`
- `Tests/DualSenseBridgeCoreTests/AdaptiveSpeechTimingTests.swift`
- `Tests/DualSenseBridgeCoreTests/MicrophoneInputTapTests.swift`
- `Tests/DualSenseBridgeCoreTests/DualSenseBluetoothAudioProtocolTests.swift`

Earlier handoffs:

- `problem.md`
- `solution.md`
- `problem2.md`
- `solution2.md`

The current build passes 59 Swift tests. The packaged app is:

`/path/to/agent-remote/dist/DualSense Bridge.app`

## Requested output from another investigator

The most useful response is not a generic list of audio-enhancement ideas.
Please provide one of the following:

1. A protocol-backed explanation and concrete HID/L2CAP control change that
   should increase the real microphone packet rate, including what log result
   would confirm it; or
2. A specific real-time reconstruction algorithm, with enough implementation
   detail to patch this Swift project, plus an offline evaluation plan using
   the archived WAV/counter/Opus files; or
3. Strong evidence that full-rate DualSense microphone audio is impossible in
   this Bluetooth mode on non-PS5 hosts, so the product can present an honest
   USB-versus-Bluetooth quality boundary.

The decisive unresolved question is:

> Can the missing 58% of real microphone frames be made to arrive over
> Bluetooth, and if not, what reconstruction method can preserve consonants
> and natural voice quality under this exact counter-shaped loss pattern?
