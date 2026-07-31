# DualSense Bridge on macOS: second handoff for the unintelligible Bluetooth microphone

Date: 18 July 2026

This is the follow-up to problem.md and solution.md in the same directory.
Those documents explain the long initial investigation and the important
receive-filter fix. This document starts from that fix and records what
happened afterward.

## Executive summary

The DualSense microphone is no longer completely silent. Real 71-byte Opus
voice packets reach the app, decode to nonzero PCM, pass through the
project-owned virtual microphone, produce a waveform in Codex, and can be
saved as WAV files. The virtual microphone itself has also passed an
independent nonzero loopback test.

The remaining blocker is packet cadence and intelligibility:

- Every DualSense mic packet begins with Opus TOC byte 0xd4.
- libopus confirms that this TOC represents 480 samples at 48 kHz: exactly
  10 ms of audio.
- A healthy stream therefore needs approximately 100 real mic packets per
  second.
- This Mac receives only approximately 44.5 real mic packets per second.
- Before timing correction, the app concatenated only the received samples.
  The resulting recordings were about 2.25 times too fast and sounded noisy.
- The app was then changed to output one 480-sample frame every 10 ms and to
  call Opus packet-loss concealment when no real packet was available.
- That fixed recording duration, but the latest six-second capture contained
  267 real frames and 334 concealment frames. More than half of the audio was
  synthetic concealment, so the user reported that it was inaudible and no
  words could be deciphered.
- Removing the continuous 50 Hz 0x39 speaker carrier eliminated all outbound
  backpressure but did not improve the approximately 44.5 Hz inbound rate.
  The carrier flood was wasteful, but it was not the sole cause of the missing
  mic packets.

The next investigation should focus on why complete 0x31 microphone feedback
does not reach the app at approximately 100 Hz. Do not try to solve this by
adding more PLC, stretching PCM, applying a noise filter, or raising gain.
Those can mask symptoms but cannot reconstruct a majority of missing speech.

There is also a current gain-control inconsistency: the app logs and first
sends VolumeMic 24, but its later 0x36 arming report embeds a hard-coded
SetStateData block with VolumeMic 64. The controller may therefore be running
at 64 despite the log saying 24. Any future gain test must make every outbound
state report agree.

## User-visible result at the time of this handoff

The latest direct report from the user was:

> This time it's inaudible and I can't decipher any words.

The immediately preceding user observations were:

- Earlier Square recordings sounded fast-forwarded and too noisy.
- After the timing/PLC change, the file duration and waveform looked more
  plausible, but the audio became unintelligible.
- At an earlier stage, after the receive filter was corrected, audio clearly
  reached Codex and the user said the mic appeared to work, although
  transcription reliability remained poor.

The controller was deliberately turned off after the latest test. At the time
this document was written:

    DualSense Wireless Controller [7c-66-ef-64-4b-89], connected=false

The corrected app is running and waiting for a controller. Do not restart it
while the controller is connected; see the Game Center warning below.

## Required end state

The final result must provide all of the following:

1. The DualSense touchpad controls the pointer reliably over Bluetooth.
2. Touchpad taps, physical clicks, scrolling, and drag behavior work.
3. Circle defaults to Return/Enter.
4. Triangle invokes Command-O for Codex dictation and releases it exactly
   once when Triangle is released.
5. Square remains available as a two-press mic record/play diagnostic.
6. Other face buttons can be mapped to user-selected keys or key chords.
7. The built-in DualSense mic works over Bluetooth without MetaVoice or any
   third-party cable.
8. Controller speech is intelligible at normal speed and can be transcribed.
9. Releasing Triangle stops recording.
10. The previous physical Mac input device is restored after a controller mic
    route.
11. The ordinary MacBook microphone keeps working.
12. Game Center never opens because it interpreted microphone bytes as
    controller input.

The non-audio controller behavior is currently working. This handoff is
primarily about items 7 and 8 while preserving every other item.

## Machine and project context

- Project root:
  /path/to/agent-remote
- Packaged app:
  /path/to/agent-remote/dist/DualSense Bridge.app
- Diagnostic log:
  ~/Library/Logs/Agent Remote/Agent Remote.log
- Mac:
  MacBook Air, MacBookAir10,1, Apple M1, 8 GB
- macOS:
  26.3, build 25D125
- Architecture:
  arm64
- Controller:
  Sony DualSense, product ID 0x0ce6, connected over Bluetooth
- The project directory currently has no usable Git repository metadata.
  Preserve files directly and inspect changes before editing.
- The release app bundles libopus.0.dylib.
- The app uses a project-owned open-source Core Audio HAL loopback driver
  named DualSense Bridge Mic with UID DualSenseBridgeMic_UID.
- No MetaVoice component is permitted or required.

## Important documents and reference implementations

Read these before changing the protocol:

- /path/to/agent-remote/docs/research/problem.md
  Complete history before real voice packets were accepted.
- /path/to/agent-remote/docs/research/solution.md
  Explains the silence-only receive-filter bug and the flag-bit fix.
- /path/to/ephemeral-research/ds5dongle-oled-20260718/BLUETOOTH_AUDIO_NOTES.md
  Concise description of a working Bluetooth mic implementation.
- /path/to/ephemeral-research/ds5dongle-oled-20260718/src/audio.cpp
  Known implementation of 398-byte 0x36 arming, Opus decoding, jitter
  buffering, and PLC.
- /path/to/ephemeral-research/ds5dongle-oled-20260718/src/main.cpp
  Known microphone feedback classifier.
- /path/to/ephemeral-research/ds5dongle-reference-20260718/src/audio.cpp
  Another DS5Dongle implementation.
- /path/to/ephemeral-research/viiper-dualsense-mic-20260718
  Additional DualSense research and device implementation.

The OLED reference explicitly documents approximately 100 mic packets per
second, 71 Opus bytes per packet, mono decode at 48 kHz, and 480 decoded
samples per packet.

## What is conclusively working

### Raw Bluetooth ownership and ordinary controller input

DualSenseBluetoothEnhancedModeEnabler opens the Bluetooth HID device under
continuous exclusive ownership. The most recent attachment reported:

    explicit device seize=0

Raw touchpad and face-button reports work. The app distinguishes genuine
gamepad input from microphone feedback by bit 1 of the flag byte following
report ID 0x31.

### Correct microphone report classification

The original parser admitted a mic report only when the Opus payload began
with d4 ff. That pattern selects encoded silence. Real voice frames begin with
d4 followed by arbitrary range-coder bytes and were rejected.

The current parser in:

    Sources/DualSenseBridgeCore/DualSenseBluetoothAudioProtocol.swift

does the following:

1. Requires report ID 0x31.
2. Determines whether IOHID included the report-ID byte in the buffer.
3. Tests bit 1 of the flag byte.
4. Takes exactly 71 bytes beginning after the flag and audio counter.

When the report ID is in the buffer, the current layout is:

    byte 0      0x31 report ID
    byte 1      flags; bit 1 marks microphone feedback
    byte 2      rolling audio/packet counter, not yet instrumented
    bytes 3-73  71-byte Opus payload
    bytes 74-77 CRC/trailer

Current live voice packets include:

    d4 7e 1b 6c 80 bf 4d 39 a1 49 99 b5 ...
    d4 79 2b 21 03 57 d4 33 60 4a 30 ff ...
    d4 f2 1c 1a b8 e5 97 ee a2 4d 0d e1 ...

These are not silence-only packets, and they decode to nonzero PCM.

### Opus configuration

BluetoothOpusDecoder creates:

    opus_decoder_create(48000, 1, ...)

and calls opus_decode with a maximum output size of 480 mono samples.

An independent call to the bundled/system libopus function:

    opus_packet_get_samples_per_frame([0xd4], 48000)

returned:

    480

Therefore the 0xd4 packets represent 10 ms, not approximately 22.5 ms. Treating
44.5 arriving packets per second as a complete stream is not a valid sample
rate reinterpretation.

### Project-owned virtual microphone

The virtual HAL driver is self-contained and open source. It is not
MetaVoice. A direct driver loopback test previously produced:

    callbacks=79 peak=0.250

This establishes that nonzero PCM written to the output side can appear on
the input side. The current failure is already audible in the diagnostic WAV
captured before the virtual microphone, so the HAL driver is not the leading
cause of this particular intelligibility problem.

### Default-input restoration

The app remembers a previous physical input, refuses to remember a virtual
device as the previous input, restores the physical input after deactivation,
unmutes it, and repairs a stranded virtual default at the next app launch.

The latest sessions repeatedly logged:

    restored previous default input to MacBook Air Microphone

Do not remove this behavior. Earlier experiments temporarily broke the normal
MacBook microphone system-wide.

### Square record/play diagnostic

Square is reserved by default for Record & Play:

- first Square press starts the Bluetooth controller route and recording;
- second Square press stops it after a short tail;
- PCM is captured before the virtual microphone;
- a mono 16-bit 48 kHz WAV is saved;
- the file is played automatically.

Files are stored in:

    /path/to/private-audio-fixtures

This diagnostic is essential because it separates controller decode quality
from Codex transcription.

## Current outbound microphone sequence

The present start sequence in
Sources/DualSenseBridge/DualSenseBluetoothEnhancedModeEnabler.swift is:

1. Seize the Bluetooth HID device.
2. Send the minimal 0x31 unmute state three times about 12 ms apart.
3. Send a 0x31 internal-microphone source report:
   - AudioControl 0x09: internal CHAT/ASR path
   - AudioControl2 0x0a
   - logged VolumeMic 24
4. Send compact 142-byte report 0x32 with stream-control payload 0x03.
5. Start a 250 ms timer.
6. While no mic feedback has arrived for one second, send the known 398-byte
   control-only 0x36 arming report.
7. Once feedback is recent, stop resending 0x36 because the stream is sticky.

The continuous 547-byte 0x39 report at 50 Hz is no longer sent.

Important inconsistency:

- internalMicrophoneSourceReport uses the selected gain, currently 24;
- microphoneArmingReport copies microphoneArmingState;
- microphoneArmingState hard-codes VolumeMic at byte 6 to 0x40, or 64;
- the 0x36 arrives after the separate gain-24 report and can overwrite it.

Thus this live log line is not proof that the final active gain was 24:

    Bluetooth microphone capture profile selected: Sony internal CHAT/ASR, gain=24

The following 0x36 likely restored gain 64. Refactor the arming builder to
accept the selected gain before evaluating noise or loudness.

## The decisive recording comparison

### Before fixed-cadence playout

File:

    /path/to/private-audio-fixtures/DualSense Mic 2026-07-18 18.20.52.wav

Observed live span:

    first mic frame: 2376164.078
    stream stopped:  2376175.431
    wall span:       approximately 11.35 seconds

Recorded real frames:

    497 frames * 480 samples = 238,560 samples
    WAV duration at 48 kHz = 4.97 seconds
    real packet rate = approximately 43.8 packets/second

The app decoded and concatenated every received frame immediately. It did not
represent missing time. That is why approximately 11.35 seconds of real time
played in 4.97 seconds, or roughly 2.28 times normal speed.

FFmpeg statistics:

    peak level     approximately 0.00 dBFS
    RMS level      approximately -18.12 dBFS
    noise floor    approximately -35.74 dBFS
    absolute peaks 10

The file clipped and the user described it as fast-forwarded and too noisy.

### After 10 ms playout and Opus PLC

File:

    /path/to/private-audio-fixtures/DualSense Mic 2026-07-18 18.31.37.wav

Observed live span:

    first mic frame: 2376814.518
    stream stopped:  2376820.522
    wall span:       approximately 6.00 seconds

Summary logged by the app:

    decoded=267
    nonSilent=267
    concealed=334
    jitterDrops=0
    maximumPeak=13599

Resulting output:

    real frames:        267
    PLC frames:         334
    total output frames 601
    WAV duration:       6.01 seconds
    real packet rate:   approximately 44.5 packets/second
    PLC proportion:     approximately 55.6 percent

FFmpeg statistics:

    peak level  approximately -7.64 dBFS
    RMS level   approximately -35.55 dBFS
    noise floor approximately -63.86 dBFS

The duration now matches wall time, so the fast-forward symptom is fixed.
However, Opus PLC is designed to hide occasional loss, not synthesize most of
a sentence. With 334 missing frames among 601 output frames, intelligibility
cannot be expected. The user could not decipher any words.

## Relevant excerpt from the latest live log

    Bluetooth microphone capture profile selected: Sony internal CHAT/ASR, gain=24, result=0
    Bluetooth microphone HID return stream enabled
    Bluetooth PS5 mic routed through DualSense Bridge Mic
    Bluetooth microphone control-only 0x36 arming report #2 sent
    Bluetooth microphone Opus frame #1, bytes=71, prefix=d4 7e 1b ...
    Bluetooth microphone steady 10 ms playout started; buffered=7
    Bluetooth microphone decoded frame #1, peak=5252
    Bluetooth microphone decoded frame #2, peak=6542
    Bluetooth microphone decoded frame #3, peak=13599
    Bluetooth microphone concealed missing packet #1
    Bluetooth microphone concealed missing packet #2
    Bluetooth microphone concealed missing packet #3
    Bluetooth microphone concealed missing packet #100
    Bluetooth microphone Opus frame #100 ...
    Bluetooth microphone decoded frame #100, peak=129
    Bluetooth microphone concealed missing packet #200
    Bluetooth microphone Opus frame #200 ...
    Bluetooth microphone decoded frame #200, peak=358
    Bluetooth microphone concealed missing packet #300
    Bluetooth microphone HID duplex stream stopped; inputFrames=267, queuedOutputFrames=1, pendingOutputFrames=0
    Bluetooth microphone writes drained without invalid disable; completed=0, failed=0, backpressureDrops=0
    Bluetooth microphone audio summary: decoded=267, nonSilent=267, concealed=334, jitterDrops=0, maximumPeak=13599
    restored previous default input to MacBook Air Microphone
    mic test recording saved; duration=6.01s, samples=288480, peak=13599

The important negative evidence is:

    completed=0, failed=0, backpressureDrops=0

There was no continuous asynchronous output traffic in this build, yet the
real input rate remained approximately 44.5 Hz.

## Current fixed-cadence implementation

DualSenseAudioInputManager now:

- buffers up to eight 71-byte Opus packets;
- begins after three packets;
- runs a DispatchSourceTimer every 10 ms;
- decodes one real packet when available;
- calls opus_decode with a null packet for PLC when the queue is empty but
  feedback was seen within 300 ms;
- sends each 480-sample result to both the virtual microphone and Square WAV
  capture;
- logs real, concealed, and dropped frame counts.

This fixed time compression and is useful diagnostic instrumentation. It is
not a solution to sustained 55 percent loss. Keep it, but do not judge audio
quality until the real packet rate is close to 100 Hz.

## What the latest experiments prove and disprove

### Proven

- Voice packets are correctly distinguished from genuine gamepad packets.
- Payload offset and Opus TOC are plausible enough for libopus to decode
  hundreds of nonzero frames.
- Each packet decodes as 480 samples at 48 kHz.
- Real packets arrive at only about 44 Hz across multiple capture designs.
- Immediate concatenation explains the old fast-forward symptom.
- A fixed 10 ms playout clock fixes duration.
- More than half the latest output required PLC.
- The latest unintelligibility exists in pre-virtual-device WAV data.
- Removing the 50 Hz 0x39 carrier removed backpressure but did not restore a
  100 Hz input rate.
- The MacBook microphone was restored after the route.
- Square down/up was recognized correctly.
- The current app did not launch Game Center during the latest tests.

### Disproven or no longer leading

- The virtual microphone alone is not causing the saved WAV corruption.
- The WAV header is not what made the old file fast; its 48 kHz header is
  correct for 480-sample Opus frames.
- Re-labeling the file as roughly 21.3 kHz is not a valid protocol fix.
- The 50 Hz outbound carrier flood is not the sole reason for the 44 Hz input
  rate.
- More aggressive PLC cannot recover the missing phonetic information.
- Peak level alone is not evidence of intelligible speech.

### Still unknown

- Whether the controller is transmitting only about 44 mic packets per second
  under the current hybrid 0x31 + 0x32 + 0x36 state.
- Whether it transmits approximately 100 but IOHID/macOS drops more than half.
- Whether missing mic packets arrive under another report ID or layout.
- Whether byte 2 of mic feedback shows contiguous packet counters or jumps.
- Whether the high nibble of the feedback flag can establish dropped raw HID
  sequence numbers after accounting for interleaved gamepad reports.
- Whether preceding the 0x36 arming report with compact 0x32 changes the
  controller feedback cadence.
- Whether the known implementation must be reproduced without the separate
  sparse 0x31 source report.
- Whether callbacks scheduled on the current main run loop lose reports under
  Core Audio or UI load.
- Whether an IOHIDQueue or dedicated HID run loop receives a different rate.
- Whether another DualSense firmware revision needs a different output report
  cadence even though the packet builders match the references.

## Highest-value next investigation

### 1. Instrument the raw input before changing audio processing

Capture at least ten seconds of every input report while the mic is active.
For each report store:

- monotonic arrival timestamp at microsecond or nanosecond resolution;
- report ID argument from IOHID;
- actual buffer length;
- whether the report buffer includes the report ID;
- first four bytes;
- flag byte;
- high-nibble transport sequence;
- byte 2 microphone packet counter for flagged reports;
- whether it was classified as mic or gamepad.

Do not log full reports synchronously to a text file from the HID callback.
Use an in-memory fixed-size ring or compact binary records, then write after
capture. Logging itself must not create the packet loss being measured.

Calculate:

- all input reports per second by report ID;
- mic-flagged reports per second;
- gamepad reports per second;
- arrival-delta histogram;
- flag/high-nibble sequence gaps;
- microphone packet-counter gaps;
- duplicate counters;
- out-of-order counters.

The mic packet counter is the fastest discriminator:

- contiguous counter values at 44 Hz imply the controller is only producing
  44 Hz under the current outbound state;
- counter jumps imply loss before or inside the Mac input callback;
- approximately 100 raw flagged reports but only 44 parser callbacks imply an
  app-side classification or queueing bug.

### 2. Count every report ID and length

The current parser only considers report ID 0x31 for mic audio. Confirm with a
raw histogram that the missing 10 ms frames are not delivered under 0x32,
another report ID, an ID-less 77-byte layout, or a coalesced transport form.

### 3. Test exact outbound implementations, one fresh link at a time

The controller microphone mode is sticky. Disconnect and reconnect Bluetooth
between protocol variants. Never switch several output states during one
session and then attribute the result to the last one.

Suggested variants:

A. Exact OLED 0x36 behavior:

- one internally consistent full SetStateData block;
- 398-byte 0x36 at approximately 4 Hz only until mic feedback begins;
- no preceding compact 0x32 if the reference does not send it in that path;
- no separate sparse 0x31 source override;
- no 0x39 speaker carrier.

B. Current compact-enable path:

- the known 0x31 state/unmute controls;
- compact 0x32 enable;
- no subsequent 0x36 overwrite;
- no 0x39 carrier.

C. Exact alternate DS5Dongle transport:

- reproduce one known working reference byte-for-byte, including report
  length, control flags, buffer lengths, audio counter, sequence behavior,
  and cadence;
- do not combine pieces from two references.

For every variant, the first pass/fail criterion is real mic packets per
second and counter continuity, not waveform peak.

### 4. Make gain state internally consistent

Parameterize microphoneArmingState or build it dynamically so every report
uses the selected VolumeMic. Test a conservative gain such as 24 and a normal
gain such as 40 only after confirming the same value remains active.

The latest gain-24 result is invalid as a controlled gain experiment because
0x36 subsequently embeds gain 64.

### 5. Isolate the macOS HID delivery mechanism

If the controller packet counter jumps:

- move input report processing off the main run loop;
- compare IOHIDManagerRegisterInputReportCallback with a device-level callback
  or IOHIDQueue;
- preallocate the largest report buffer required by 0x31 feedback;
- ensure no synchronous Core Audio setup or output report call blocks the HID
  callback run loop;
- record callback service time and any kernel/IOKit overrun indicators.

There was a roughly 2.8-second pause between the first Square-down log and the
first unmute report in one test, likely during synchronous Core Audio startup.
Queued ordinary reports were then delivered in a burst. That startup delay is
not enough to explain the steady 44 Hz rate, but it proves the current run loop
can be blocked and should be isolated during packet-cadence measurement.

### 6. Only then tune playout and audio quality

Once real delivery is at least approximately 95 packets per second:

- keep the three-frame jitter prebuffer;
- expect PLC to remain near zero on a good link;
- record ten seconds with spoken counting and silent pauses;
- check real-time duration;
- check clipping;
- tune one consistent controller gain;
- consider a light high-pass filter only if ordinary low-frequency rumble
  remains;
- do not add a noise gate until intelligible raw speech is established.

## Useful source files

Controller transport and parsing:

    Sources/DualSenseBridgeCore/DualSenseBluetoothAudioProtocol.swift
    Sources/DualSenseBridge/DualSenseBluetoothEnhancedModeEnabler.swift

Opus decoding and fixed-cadence playout:

    Sources/DualSenseBridge/BluetoothOpusDecoder.swift
    Sources/DualSenseBridge/DualSenseAudioInputManager.swift

Virtual mic output:

    Sources/DualSenseBridge/VirtualMicrophonePCMOutput.swift
    Driver/
    scripts/build-driver.sh
    scripts/install-driver.sh
    Tools/DualSenseBridgeMicHALTest.c

Button behavior and settings:

    Sources/DualSenseBridge/ControllerBridge.swift
    Sources/DualSenseBridge/BridgeSettings.swift
    Sources/DualSenseBridge/ButtonMappingWindowController.swift
    Sources/DualSenseBridge/StatusMenuController.swift

App startup and HID-first isolation:

    Sources/DualSenseBridge/main.swift

Tests:

    Tests/DualSenseBridgeCoreTests/DualSenseBluetoothAudioProtocolTests.swift
    Tests/DualSenseBridgeCoreTests/

## Build and diagnostic commands

Run the full suite:

    env CLANG_MODULE_CACHE_PATH=/path/to/ephemeral-research/dualsense-swift-module-cache \
        SWIFTPM_MODULECACHE_OVERRIDE=/path/to/ephemeral-research/dualsense-swiftpm-cache \
        swift test

Current result:

    36 tests passed

Package and sign:

    ./scripts/package-app.sh

Tail the current session:

    tail -n 300 "$HOME/Library/Logs/Agent Remote/Agent Remote.log"

Inspect a recording:

    ffmpeg -hide_banner \
      -i "/path/to/private-audio-fixtures/<file>.wav" \
      -af astats=metadata=1:reset=0 \
      -f null -

Check whether the controller is connected:

    /path/to/ephemeral-research/dualsense-session-status

The temporary helper paths are machine-local investigation tools, not
dependencies that should ship in the open-source project.

## Safety and regression constraints

### Never return to MetaVoice

The project must remain self-contained and open source. People cloning it
must not need a commercial or unrelated virtual cable.

### Restart only while the controller is off

The DualSense mic feedback stream is sticky. During an old-app/new-app
handoff, a brief period with no process seizing the HID device previously let
macOS GameController interpret proprietary mic bytes as controller input and
launch Game Center.

Safe restart procedure:

1. Turn off or disconnect the DualSense.
2. Verify connected=false.
3. Stop the old app.
4. Launch the new app.
5. Verify the log begins with HID isolation.
6. Turn the controller back on.

Expected launch ordering:

    Bluetooth HID isolated; sticky microphone feedback contained
    Bluetooth enhanced-mode HID monitor started
    app launched

### Do not send an unproven disable transition

Earlier invalid disable experiments made the controller fail to re-arm until
reconnection. Stop host routing and keep exclusive ownership rather than
sending an undocumented destructive audio state.

### Preserve the normal Mac microphone

Do not leave DualSense Bridge Mic as the default input after stopping,
disconnecting, crashing, or relaunching. Keep the current physical-input
restore and stranded-route repair.

### Do not ask for Accessibility permission again

Accessibility is already granted and is unrelated to Bluetooth audio quality.

### Preserve button-up behavior

Triangle Command-O must generate one complete down/up chord. Do not hold the
keyboard event until audio cleanup finishes.

## Acceptance criteria for a genuine fix

A result is not fixed merely because PCM is nonzero or Codex displays a
waveform. Require all of these:

1. At least about 95 real 10 ms microphone packets per second over a
   continuous ten-second capture, unless packet counters conclusively prove a
   different complete transport format.
2. Packet counter continuity, with documented handling for occasional loss.
3. PLC below approximately 5 percent on a normal nearby Bluetooth link.
4. WAV duration within five percent of wall time.
5. Spoken counting is clearly intelligible in Square playback.
6. No full-scale clipping.
7. Silent pauses sound like quiet room tone, not digital bursts.
8. Codex shows a waveform and produces the correct words.
9. Releasing Triangle stops dictation without waiting for the Mac trackpad.
10. The prior MacBook input is restored automatically.
11. The MacBook microphone still records normally afterward.
12. No Game Center launch.
13. Touchpad and face-button controls still work.
14. The build has no MetaVoice dependency.
15. The full test suite passes.

## Precise question for the next agent or external search

On macOS 26.3 with an M1 MacBook Air and a Bluetooth DualSense, why does an
exclusive IOHID input path receive only approximately 44.5 flag-bit-marked
0x31 microphone reports per second when every 71-byte 0xd4 Opus packet is
provably a 480-sample/10 ms frame and working DS5Dongle implementations report
approximately 100 frames per second? Determine whether packets are absent at
the controller because of the current hybrid 0x31/0x32/0x36 outbound state,
lost in macOS/IOHID, or present under an uncounted report layout. Use the
feedback packet counter and complete raw report-rate instrumentation to prove
which layer loses them, then reproduce one known working transport exactly
and validate with intelligible ten-second speech rather than nonzero peaks.
