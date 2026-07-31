# DualSense Bluetooth microphone: third solution proposal

Date: 20 July 2026

This document answers `problem3.md`. It is based on a fresh reading of the
code, the newest archived capture (15:30 take), the two DS5Dongle reference
trees still present under `/path/to/ephemeral-research/`, and new measurements made today
against the archived diagnostic files. Sections are ordered by expected value.

## Executive summary

The decisive question in `problem3.md` was:

> Can the missing 58% of real microphone frames be made to arrive over
> Bluetooth, and if not, what reconstruction method can preserve consonants
> and natural voice quality under this exact counter-shaped loss pattern?

The answer to the first half is almost certainly **yes — on any host whose
Bluetooth link is not power-managed the way macOS manages it.** Three pieces
of evidence, two of them new today, converge on one mechanism:

1. **The working reference hardware receives the full stream.** The
   DS5Dongle-OLED tree this project already vendored
   (`/path/to/ephemeral-research/ds5dongle-oled-20260718`) states it plainly:
   `BLUETOOTH_AUDIO_NOTES.md` line 24 reports "`Mic in:` (~100/s when
   streaming)" and `src/audio.cpp:180` says the decode loop "keeps up with
   the **~100 Hz arrival rate of mic-tagged BT frames**." Same controller,
   same 0x36 arming, same sticky stream, **no continuous outbound carriers**
   (the dongle stops its 4 Hz keepalive once frames flow). The dongle is a
   Pico W running BTstack — and BTstack's default link-policy setting is 0,
   which **rejects sniff-mode requests entirely**, so its ACL link stays in
   active mode.
2. **The macOS arrival grid is a link-scheduling grid, not an audio grid.**
   1,319 reports in 20.78 s is one report every 15.75 ms. 15.625 ms is
   exactly 25 Bluetooth slots — a canonical sniff interval. The mic
   inter-arrival modes (15 ms and 30 ms) and the counter delta trigrams
   ((+1,+3,+2), (+2,+3,+1), (+3,+2,+3)…) are exactly the arithmetic of a
   100 Hz frame clock quantized onto a ~15.7 ms slot grid with one third of
   slots spent on gamepad reports. Earlier captures (see `solution2.md`)
   showed ~22.5 ms and ~11.25 ms spacings — 36-slot and 18-slot intervals,
   also canonical sniff values. **The interval changes between sessions.** A
   controller-side fixed schedule would not do that; a host link-power policy
   would.
3. **The transport sequence is contiguous.** All 1,319 reports arrived with
   the 0x31 sequence nibble advancing +1 every time. Nothing is lost between
   the controller's transmit queue and the app. The controller is generating
   100 frames/s, flushing what the link will not carry, and transmitting the
   newest frame in each slot it gets ("latest-frame-wins").

So the root-cause model in `problem3.md` ("the controller/HID schedule
selects only part of the internally generated mic stream") should be
sharpened: **the controller thins its mic stream to fit the number of
transmit opportunities the host's link schedule gives it.** Give it a link
serviced every few milliseconds — as the PS5 and the dongle do — and it
delivers everything. The bottleneck is macOS `bluetoothd` link management,
not Sony protocol state, and no amount of HID report sweeping will move it.

This yields three work streams, in order:

- **Direction A (transport):** one 30-minute PacketLogger capture proves the
  sniff picture (it has never actually been run); then a short list of cheap
  in-app probes that could keep the link active; then a Linux/BlueZ control
  experiment that will almost certainly demonstrate full rate and becomes
  the evidence base for an Apple feedback report and the product decision.
- **Direction B (reconstruction):** replace the global 2.4× SOLA stretch
  with **counter-anchored reconstruction**. New measurements below show the
  loss is not "58% missing"; it is "10–20 ms holes between exactly-placed
  islands, re-anchored to real audio every ~32 ms on average." That is a
  much easier problem than uniform 2.4× stretching, and it is the reason the
  current output is robotic while a hole-filler need not be.
- **Direction C (codec):** closed in part today. Every one of the 861
  archived packets has Opus TOC byte `0xd4` = CELT-only mode. **CELT-mode
  Opus cannot carry in-band FEC (LBRR exists only in SILK/hybrid modes).**
  The `decode_fec=1` probe would return concealment, not data. Do not spend
  any time on it.

## New measurements made today (all reproducible from the archives)

### 1. The Opus stream is CELT-only, super-wideband — FEC is impossible

Parsed `…/Diagnostics/DualSense Mic 2026-07-20 15.30.42 Opus.bin`
(`DSOPUS01` format: counter byte, little-endian length, frame):

```text
frames=861, every frame 71 bytes, every TOC byte 0xd4
TOC 0xd4 → config 26 (CELT-only, SWB, 10 ms), stereo flag set, code 0
bit rate: 71 bytes / 10 ms = 56.8 kbit/s
```

Consequences:

- **Direction C's FEC probe is closed.** RFC 6716: LBRR (in-band FEC) exists
  only in SILK and hybrid modes, configs 0–15. Config 26 is CELT-only. There
  is no redundancy in these packets, full stop.
- **The codec carries up to 12 kHz of audio bandwidth** (SWB). The current
  5 kHz low-pass is hiding splice artifacts, not codec limits. After any
  transport fix — or under the anchored reconstruction below, which designs
  the discontinuities out — the low-pass should be re-opened and the tone
  stack re-evaluated. There is real fricative energy being thrown away.
- The stereo flag suggests the controller encodes its mic array as a coupled
  pair; decoding mono (as now) downmixes in libopus and is fine.

### 2. The loss is short interleaved holes, not bulk absence

From `…/DualSense Mic 2026-07-20 15.30.42 Counters.txt`:

```text
received islands (consecutive +1 runs):
  1 frame  (10 ms) × 443
  2 frames (20 ms) × 207
  4 frames (40 ms) × 1
holes between islands (missing frames):
  1 frame  (10 ms) × 206
  2 frames (20 ms) × 396
  3 frames (30 ms) × 18
  4 frames (40 ms) × 18
  5–10 frames (50–100 ms) × 12
```

- 82.5% of all missing audio (998 of 1,210 frames) sits in holes of one or
  two frames — 10–20 ms.
- The mean island is 13.2 ms of genuine audio; the mean hole is 18.6 ms; a
  new genuine island begins every 31.8 ms on average.
- The longest hole in the entire take was 100 ms; holes ≥ 50 ms occurred 12
  times in 20.7 s and correlate with the 90 ms inter-arrival outlier
  (interference/retransmission bursts).
- The delta sequence is quasi-periodic (dominant trigrams (1,3,2), (2,3,1),
  (3,2,3), (3,1,3)) — deterministic slot arithmetic, not random loss.

This reframing matters. Filling a known-position 10–20 ms hole between two
known 10–20 ms islands is a classical, tractable concealment problem —
telephone-grade PLC conceals 20–40 ms routinely. The current pipeline
instead discards the position information (the stretcher never sees the
counter; only a single global ratio survives) and repeats every grain 2.4×,
including consonants, which is precisely the robotic signature. Direction B
below is built on this observation.

### 3. The reference implementation numbers line up

The controller's own counter implies 99.8 generated frames/s; the dongle
measures ~100 received frames/s; the macOS tap measures 41.4/s on a 15.75 ms
report grid with a 2:1 mic:gamepad slot share (41.4 ≈ 63.4 × ⅔). Nothing in
these numbers requires a Sony-side decimation mode to explain, and the
dongle's full-rate receipt in the *same capture profile* rules one out.

## Direction A: recover the full stream

### A0. What almost certainly is happening (to be proven, then acted on)

macOS puts Bluetooth Classic HID links into sniff mode with a short service
interval as its steady-state power policy (Apple's own input devices operate
in sniff at 11.25–15 ms intervals by design; third-party gamepads on macOS
are widely reported to deliver ~60–90 Hz over BT versus 250 Hz+ on Windows,
Linux, and PS5). In sniff mode the slave gets transmit opportunities only at
anchor points. The DualSense therefore gets ~64 opportunities/s and spends
~22 of them on gamepad state; 100 mic frames/s cannot fit, and the firmware
flushes the backlog, transmitting the newest frame per opportunity — which
is exactly the observed +1/+2/+3 counter arithmetic.

The 5 ms `kIOHIDReportIntervalKey` request is honored by transports that
poll (USB interrupt endpoints); the Bluetooth HID driver does not translate
it into a link-policy change, which is why it changed nothing.

### A1. Prove it with one PacketLogger capture (~30–60 minutes)

This has been recommended since `solution2.md` but never run. It converts
the entire hypothesis into two log lines and de-risks everything after it.

Steps:

1. Download **Additional Tools for Xcode** (developer.apple.com, matching
   the installed Xcode) and copy `PacketLogger.app` out of the Hardware
   folder. On current macOS you must also install Apple's **Bluetooth
   diagnostic/logging profile** (developer.apple.com → Bug Reporting →
   Profiles and Logs → Bluetooth) and reboot Bluetooth, or the capture will
   be empty.
2. Start a capture, run one normal Square take (the reproduction protocol in
   `problem3.md`), stop the capture. The controller's address is
   `7C:66:EF:64:4B:89` — find its `Connection Complete` to get the ACL
   handle. PacketLogger's `.pklg` also opens in Wireshark if filtering is
   easier there.
3. Read out, in order:
   - **`Mode Change` events** for that handle: `Sniff` vs `Active` and the
     interval in slots. The expectation is sniff with interval ≈ 25 slots
     (15.625 ms). Note *when* it entered sniff (at connect? seconds after?)
     and whether the host sent `HCI_Sniff_Mode` (host-initiated) or only the
     event appears (remote-initiated / controller-chip policy).
   - **Sniff-subrating events**, if any.
   - The **per-second count of inbound ACL packets carrying 0x31 input
     reports with the mic flag** (byte 2 bit 1). Expectation: ≈ 41/s on air,
     i.e. the missing counters are *absent over the air*, not dropped in
     IOKit. This closes `problem3.md` Direction A question 6.
   - Any **inbound L2CAP `Connection Request` from the controller being
     rejected** (an unknown PSM the controller tries to open). Expectation:
     none — the dongle receives everything on the standard HID interrupt
     channel — but if one appears, that is a second-channel lead worth its
     own investigation. This closes question 4.
   - Who is master after connect (role switch events), for the record.

Decision tree:

- **Sniff confirmed at ~25 slots** → proceed to A2/A3/A4. The controller and
  the app are exonerated; stop sweeping Sony report fields for rate.
- **No sniff; link active and packets still ~64/s** → the throttle is the
  master's poll cadence (`Tpoll`/QoS) rather than sniff anchors. Same
  remediation list (it is still host link scheduling), but the Apple
  feedback should describe poll interval instead of sniff.
- **~100 mic packets/s on air but 41/s at the tap** → host-side drop inside
  IOKit/IOBluetooth (contradicts the contiguous sequence nibble, so this is
  very unlikely) — would redirect the work entirely to the HID stack.

### A1b. Free corroboration without PacketLogger (~20 minutes)

Add a debug command that runs `DualSenseMicrophoneInputTap` for ten seconds
**without arming the microphone** (gamepad-only traffic), and log the rate.
If idle gamepad reports also arrive on a ~15.7 ms grid (~64/s), the grid is
the link's, not the audio mode's. If gamepad-only runs much faster and the
rate *drops* to 64/s only when the mic session starts, that suggests
bluetoothd renegotiates the link when traffic patterns change — useful
detail for A2. Either way this is one small patch to code that already
exists (`inputTap` is currently gated to mic sessions in
`DualSenseBluetoothEnhancedModeEnabler.startMicrophoneStream`).

While in there, make the tap emit a **2-second rolling rate line during the
session** (received/s by class). Every A2 experiment below becomes
instantly measurable instead of requiring a full take + log read.

### A2. Cheap in-app probes that might keep the link fast (public API)

Each is under an hour with the live rate line from A1b. Expectations are
honest: none is likely to beat a deliberate OS power policy, but they are
the only shippable in-app levers, so they must be tried and recorded.

1. **Steady small outbound cadence.** During streaming the app currently
   sends almost nothing (keepalive only after a 1 s stall). Some stacks hold
   links active while traffic flows. Send the known-safe 78-byte LED-only
   report (`lightbarColorReport`, unchanged color) every 20 ms via the
   existing-but-unused `sendAsynchronously` path with its 8-write
   backpressure cap. Watch the inbound rate. Try 50 ms and 10 ms variants.
   Note: this is *not* the previously-rejected 0x39 flood — 547-byte
   carriers fragment into several ACL packets and, under sniff, starve the
   very anchors the mic needs, which is consistent with the earlier
   observation that they "block incoming reports." Keep outbound single-ACL
   sized (≤ ~120 bytes) for this probe.
2. **Non-HID ACL activity.** Fire `-[IOBluetoothDevice performSDPQuery:]` at
   the controller every 500 ms during a capture (the app already links
   IOBluetooth for `Tools/ExistingL2CAPProbe.m`-style work). SDP traffic
   rides the same ACL; if bluetoothd exits sniff for "busy" links, this
   triggers it without touching the HID channel.
3. **Report-interval properties on the Bluetooth HID service.** Inspect
   `ioreg -l -w0 | grep -B4 -A8 IOBluetoothHIDDriver` for properties like
   `ReportInterval`/`PollInterval` on the DualSense node, and try setting
   them via `IORegistryEntrySetCFProperty` from a root helper as a
   diagnostic (not shippable, purely to see whether the driver exposes a
   knob the property on the IOHIDDevice plane does not reach).
4. **Combined best-known state.** If any probe moves the rate at all, rerun
   the standard take and archive the counters — even a partial win changes
   Direction B's operating point dramatically (see B7).

Success criterion for the whole direction (from `problem3.md`, unchanged):
≥ 90–95 real mic frames/s, counter gaps < 5%, zero duplicates/backwards. In
logs: `mic input tap mic counter: deltas=[+1×N]`-dominated,
`estimatedGenerated≈received`, and `required expansion ratio≈1.0`.

### A3. The Linux control experiment (half a day, high information value)

Replicate the arming sequence on a Linux box (or VM with USB-BT dongle —
not macOS-virtualized Bluetooth) with BlueZ, and measure. This is the
experiment that turns "probably the macOS link policy" into a documented
platform comparison using the same controller and the same bytes.

Sketch:

1. Pair the DualSense; `hid-playstation` binds it and creates
   `/dev/hidraw*`. Bluetooth output reports can be written to the hidraw
   node directly.
2. Replay the exact byte sequences from
   `DualSenseBluetoothAudioProtocol.swift` (they are host-agnostic):
   unmute ×3 (`microphoneStateReport(muted: false)` bytes), profile report
   (`internalMicrophoneSourceReport` with 0x09/0x0a), then the 0x32
   `audioReport(microphoneEnabled: true)`. The Sony CRC32 (seed byte 0xa2)
   comes along for free since the app's builders already produce full
   framed reports. A ~60-line Python script (`open('/dev/hidrawX','wb')`,
   plus a reader thread printing report-ID/flag/counter rates) is enough.
3. Watch `btmon` in a second terminal: it shows Mode Change events, sniff
   intervals, and every ACL packet without any profile installation.
4. Record: inbound mic-tagged reports/s and counter deltas. Expected result,
   given the dongle: **~100/s with deltas ≈ +1** because BlueZ does not put
   an active HID link into sniff on its own.
5. If — unexpectedly — Linux also shows ~64/s: check `Mode Change` in
   btmon; if sniffed, disable sniff in the link policy
   (`sudo btmgmt` / `hciconfig hci0 lp RSWITCH,HOLD,PARK`, i.e. remove
   SNIFF) and re-measure. If it *still* sits at 64/s in active mode, the
   controller-side-schedule theory revives and the 0x91 config sweep (A5)
   gets promoted. This is the falsification path; everything currently
   points the other way.

Deliverable either way: a table — PS5-equivalent (dongle) 100/s, Linux
N/s, macOS 41/s — plus the PacketLogger and btmon traces. That is exactly
the "protocol-backed explanation" requested in `problem3.md`, and it is the
attachment for an Apple Feedback report (see A4).

### A4. macOS link-policy remediation: what is and is not realistic

- **Raw HCI from an app (exit sniff / rewrite link policy) is effectively
  closed on modern macOS.** bluetoothd owns the controller; the old
  IOBluetooth HCI SPI has been progressively locked behind entitlements, and
  even PacketLogger needs Apple's logging profile just to *observe*. Budget
  one timeboxed hour to enumerate current IOBluetooth SPI symbols out of
  curiosity, then stop. Do not build product plans on it.
- **File the Apple Feedback** with the A1 trace and the A3 comparison table:
  "Bluetooth HID sniff policy caps third-party controller input at ~64
  reports/s; PS5 controller mic streaming requires ~160/s; request a
  latency/QoS opt-out or faster service interval for HID devices with
  active high-rate traffic." Apple has adjusted BT HID scheduling before;
  it is a long lever with a real, if slow, chance.
- **Owning PSM 0x11/0x13 from user space** (the dongle's approach, on
  macOS) would require detaching Apple's Bluetooth HID driver from the
  device — not achievable in a redistributable app without kexts/system
  extensions and SIP fights, and even then bluetoothd's link policy still
  governs the ACL. Recorded here as a considered-and-rejected path so it is
  not re-litigated.
- **The honest hardware answer if all of the above fails** is Direction D,
  reframed: the *controller* is not the limit; *macOS Bluetooth policy* is.
  Product options in order of user value: (1) Bluetooth mode with Direction
  B reconstruction (materially better than today — see below), disclosed as
  "limited by macOS Bluetooth scheduling"; (2) USB-C mode with the native
  Core Audio mic (already works); (3) for enthusiasts, the DS5Dongle
  hardware path exists and is open-source — a $10 Pico W presents the
  controller as a USB mic at full rate. The app should detect and prefer
  the native/USB paths automatically when present (it already prefers USB).

### A5. Timeboxed protocol sweeps (demoted, with two specific targets)

The dongle evidence makes a hidden "full-rate Bluetooth mode" switch
unlikely — the controller already sends full rate when the link lets it.
Two narrow sweeps remain worth one timeboxed session each, run *with* the
live rate line so each variant costs seconds:

1. **Gamepad-slot suppression.** ~22 of ~64 slots/s carry gamepad state the
   mic session mostly ignores. If any 0x91 config bit or SetState flag
   suppresses or decimates gamepad input reports during capture, mic
   delivery rises to ~63/s and — more importantly — the counter deltas
   collapse to +1/+2 (islands lengthen, holes shrink to ≤10 ms two-thirds
   of the time), which Direction B converts into near-transparent output.
   Sweep the 0x91 flag byte (currently 0x03 in the compact 0x32 enable;
   0xff/0x7f in the large carriers) and the five 64-valued buffer fields,
   one field at a time, watching *both* the mic rate and the gamepad rate.
2. **Multi-frame packing.** Watch for any input report with ID ≠ 0x31 or
   length > 78 during the sweeps (the tap already records IDs; add a length
   histogram). Two 71-byte frames per report at the current slot rate would
   also reach ~83–128 frames/s. No public reference shows Sony batching mic
   frames (the PS5 does not need it at its polling rate), so expectations
   are low — this is a "log it while doing other work" check, not a
   project.

Safety notes from project history remain in force: no bogus disable
transitions (stream is sticky until reconnect), keep LED ownership separate
from audio state, one variable per run, archive counters for every variant.

### Answers to problem3.md's eight Direction A questions

1. **Why 63–64/s despite a 5 ms request?** Host link scheduling (sniff /
   service interval on a ~15.7 ms grid ≈ 25 slots). `kIOHIDReportInterval`
   does not reach the Bluetooth link policy. A1 confirms.
2. **Mic-priority control?** Unknown; A5 sweeps it. But under the current
   link even perfect slot allocation caps at ~64/s — the link, not the
   allocation, is the primary limit.
3. **Is CHAT/ASR a decimated ASR stream?** No. The dongle receives ~100/s
   in the same profile. The decimation is link-rate adaptation
   (latest-frame-wins flush), not a profile property.
4. **Non-HID L2CAP voice channel?** No evidence: the dongle receives
   everything on the standard HID interrupt channel. A1's check for
   rejected inbound connection requests is the final confirmation.
5. **Do outbound carriers consume the budget / gate the stream?** The
   stream needs no continuous carriers (dongle stops keepalives; stream is
   sticky). Under sniff, large outbound carriers actively *hurt* (multi-ACL
   fragments compete for anchors) — matching the earlier macOS
   observation. Small-report cadence as a keep-awake probe is A2.1.
6. **Air-vs-IOKit loss?** PacketLogger per A1; expectation: absent on air.
   The contiguous transport nibble already implies it.
7. **Open-source documentation of the full BT return path?** Yes — the
   vendored DS5Dongle trees; `BLUETOOTH_AUDIO_NOTES.md` documents arming,
   sticky behavior, and the ~100/s rate. The Linux kernel driver still
   documents BT audio as unsupported; SDL/Chiaki do not implement it.
8. **Is the counter per encoded frame?** Yes — 99.8/s estimated from
   counters matches the dongle's ~100/s received and the output-duration
   evidence.

## Direction B: counter-anchored reconstruction (replaces global SOLA)

### B0. Why the current approach cannot stop sounding robotic

The pipeline (`SpeechCorrectedPCMOutput.enqueue`) reduces the counter to a
single scalar ratio, concatenates non-adjacent 10 ms snippets into a
compacted stream, and stretches that stream 2.4× with SOLA. Two structural
problems follow, no matter how the SOLA parameters are tuned:

1. Every surviving grain — including consonants and transients — is
   repeated ~2.4×. Repetition of aperiodic material is the classic robotic
   artifact, and the measured 99.9th-percentile derivative (4× the MacBook
   value) is its fingerprint.
2. Splices join waveform segments that were never adjacent, at arbitrary
   phase. The 5 kHz low-pass exists to mask exactly this, and it discards
   half the codec's real bandwidth (measurement 1 above).

The counter analysis (measurement 2) shows what the pipeline is throwing
away: every received frame has an exact true-time address, real audio
re-anchors the timeline every ~32 ms, and 82.5% of what must be synthesized
is 10–20 ms holes with genuine audio on both sides. The correct primitive is
not "stretch a compacted stream," it is **"place every real frame at its
true position, and fill each short hole using both of its neighbors."**

This supersedes the `problem3.md` Direction B sketch (transient-protected
debt allocation): anchoring gives transient protection for free — real
consonants play exactly once, at exactly their true time, verbatim — and no
debt bookkeeping is needed because output duration is exact by construction.

### B1. Why this is not the already-tried-and-failed gap filling

`problem3.md` lists failed variants: frame repetition, linear interpolation,
bidirectional morphing, pitch-periodic extension, LPC extrapolation, hybrid
gap-insert + residual stretch. Each failed for an identifiable mechanical
reason that the design below removes explicitly:

| Past attempt | Failure mechanism | Design element that removes it |
|---|---|---|
| Repeat previous frame | 10 ms verbatim loop = 100 Hz buzz + phase break at each seam | Never loop frames; synthesize by pitch-cycle advance with continuous phase |
| Linear interpolation of frames | Averaging out-of-phase waveforms = comb filtering/cancellation | Interpolate *parameters* (period, gain, envelope), never raw waveforms |
| Bidirectional morphing | Same phase-blind mid-hole crossfade | Phase-aligned landing: warp the final synthesized cycles so the fill meets the right island at matched phase |
| Pitch-periodic extension | Butt-joined right edge at arbitrary phase; per-frame processing with no evolving context; energy steps | Explicit phase-meeting warp; synthesis continues from the *continuous* left output (real + prior fill), not isolated frames; per-cycle energy interpolation |
| LPC extrapolation | Noise-excited LPC applied to voiced speech = buzz; unstable extension | LPC/noise used **only** for unvoiced fills; voiced fills stay in the waveform domain |
| Gap insert + residual stretch | Consonants still stretched; two artifact families compound | Zero stretch anywhere, ever |

The other repeated failure mode — "boundary value/slope repair" clicking at
the ~63 Hz report rate — disappears because seams occur only at hole
boundaries (~31/s), are pitch-aligned, and are crossfaded over milliseconds.

### B2. Algorithm specification

New type in `DualSenseBridgeCore`, e.g.
`DualSenseAnchoredSpeechReconstructor`, replacing
`DualSenseAdaptiveSpeechTiming` + `DualSenseSpeechTimeStretcher` in
`SpeechCorrectedPCMOutput`. API mirrors the existing call site, which
already has both inputs:

```swift
// in SpeechCorrectedPCMOutput.enqueue(_ samples: [Int16], counter: UInt8)
let reconstructed = reconstructor.process(samples, counter: counter)
if !reconstructed.isEmpty { output.enqueue(finishingFilter.process(reconstructed)) }
// plus reconstructor.flush() on session end
```

**Timeline.** Unwrap the 8-bit counter to a 64-bit position (the input tap
already does modular unwrapping; reuse that logic). Output cursor = first
counter position; each subsequent position owns exactly 480 output samples.
Duration is exact by construction — acceptance criterion 7 is free, and the
2.32 startup prior plus 48-frame hold become unnecessary (first island
plays immediately; the first hole is filled like any other).

**Lookahead.** Buffer islands until the next island arrives or the pending
hole exceeds 120 ms (forced unilateral fill, then re-anchor when the next
island shows up). Typical added latency = one hole + one island ≈ 30–40 ms,
absorbed several times over by the existing 300 ms prebuffer. (Once stable,
the prebuffer can drop to ~150 ms — a net *latency improvement* over
today.)

**Per-island analysis** (cheap, time-domain, dependency-free):

- RMS energy (dBFS) and an adaptive noise floor (minimum-tracking).
- Zero-crossing rate.
- Normalized autocorrelation over the island plus up to 20 ms of the
  already-synthesized left context, lags 120–600 samples (80–400 Hz — same
  range the SOLA code uses today) → best period `T` and periodicity `p`.
- Smooth `T` across islands with true-time-aware continuity (holes are
  20–30 ms; pitch moves little across them; reject octave jumps unless
  sustained).

**Hole classification** by flanking islands:

- **Silence** (both sides within 6 dB of floor): emit comfort noise at the
  floor with 2 ms edge fades. (Today, silence gets stretched too.)
- **Voiced–voiced** (`p ≥ 0.55` both sides; threshold to be tuned offline —
  anchored filling degrades more gracefully than SOLA widening did at 0.30):
  pitch-cycle continuation. Take the last complete cycle of the left
  context as a two-period Hann grain (standard PSOLA); place copies
  advancing by `T(t)` linearly interpolated from `T_left` to `T_right`;
  scale each cycle by a gain interpolating left-island RMS → right-island
  RMS. Before landing: cross-correlate the last two synthesized cycles
  against the right island's first two cycles over ±T/2; time-warp the
  final 1–2 cycles by ≤ 6% per cycle so the phase meets; raised-cosine
  crossfade 4 ms into the genuine right island. The genuine island samples
  are never modified beyond that 4 ms fade-in region.
- **Unvoiced–unvoiced** (fricative-like: high ZCR, low `p`): LPC(16) on
  each island (Levinson–Durbin on 480–960 samples), convert to LSF,
  linearly interpolate LSF and residual energy across the hole in 5 ms
  subframes, excite with **fresh white noise**, filter, 2–3 ms edge
  crossfades. Fresh noise is the entire point — repeated noise is what
  produced the tonal buzz in earlier attempts.
- **Mixed (V→U / U→V)**: split the hole at an energy-weighted boundary
  (midpoint when ambiguous); voiced-side continuation decays 3 dB per cycle
  into the noise fill.
- **Onset protection**: if the right island's energy jumps ≥ 9 dB over the
  left island (or spectral balance shifts sharply), never extend anything
  into the final 5 ms before it; fill that guard region at the left/floor
  level so the onset lands at its true position at full crispness with
  zero pre-echo. This is the transient-preservation half of the old
  Direction B sketch, obtained without any ratio machinery.
- **Long holes (> 60 ms, ~0.6/s in the newest take)**: fill the first
  40 ms as above, then decay 20 dB over the next 20 ms toward comfort
  noise, re-onset with a 3 ms fade at the next island — standard PLC
  practice; renders as a brief soft dropout instead of an artifact.

**Energy discipline**: synthetic material is capped at
`min(left, right) + 1 dB`; all gain trajectories are linear-in-dB over the
hole. This kills the tremolo/pumping failure mode at its source.

**Cleanup interaction**: run the reconstructor on *unfiltered* decoder
output; keep the 70 Hz high-pass; in offline evaluation, open the low-pass
from 5 kHz to 8–10 kHz (the artifacts it was hiding are designed out, and
measurement 1 shows the codec delivers real SWB content). Re-evaluate the
finishing EQ (+2.5 dB/180 Hz, −2 dB/500 Hz) from scratch on the new
output — it was tuned to compensate the SOLA path.

**CPU**: worst case ~42 islands/s × autocorrelation over ≤ 600 lags ×
~600 samples ≈ 15 M multiply-adds/s plus trivial LPC — negligible against
the current SOLA search (which correlates every sample at stride 1).

### B3. Expected result, stated honestly

- Voiced segments (the large majority of speech energy): near-transparent.
  Pitch cycles bridge 10–30 ms holes with phase-coherent, energy-matched
  material — this is squarely inside what concealment does well, and there
  is no 2.4× repetition left anywhere to sound robotic.
- Fricatives: good — spectrally-matched fresh noise across 10–20 ms is
  perceptually seamless.
- Plosives/stops whose burst falls **entirely inside** a hole: genuinely
  unrecoverable, by information theory rather than algorithm choice. With
  396 20 ms holes per ~21 s, a handful of bursts per utterance will land
  fully inside holes and come out as a plausible-but-soft transition.
  Expect residual word errors ("find out" → weaker /f/ …) at a much lower
  rate than today's whole-utterance degradation, but not zero. Only
  Direction A eliminates this class.
- Acceptance criteria: 7 (duration) holds by construction; 8's remaining
  risks are only in fills, which are bounded and re-anchored every ~32 ms;
  6 improves slightly (no ratio-convergence warm-up).

### B4. Offline evaluation plan (before touching the live path)

The archived triples make this a pure offline exercise; all four archives
must be replayed (per the project's own rule).

1. Small SPM executable target (or a `Tools/` file in the existing style),
   `AnchoredReplayTool`: reads a `Counters.txt` + `Opus.bin` pair, decodes
   with the existing `BluetoothOpusDecoder` (real packets only, exactly as
   live), runs the reconstructor, writes `… Anchored.wav`.
2. Metrics per archive, versus the archived processed output of the current
   path:
   - `tiny.en` Faster-Whisper transcript vs the fixed reference phrase
     (word error count — the project's own primary criterion);
   - DNSMOS OVRL/SIG;
   - 99.9th-percentile first-derivative (the project's discontinuity
     fingerprint; expect it to drop toward the MacBook's ~0.008);
   - output duration vs counter timeline (< 1%).
3. Gate: word recognition improves on the newest pair and regresses on none
   of the three older archives; derivative statistic materially improves.
   Only then wire it into `SpeechCorrectedPCMOutput` behind a settings flag
   for A/B listening.
4. Cheap ablation while the harness exists: for **single-frame holes only**
   (206 of 650 holes), compare the waveform fill against cloned-state Opus
   PLC (`OPUS_RESET_STATE`d shadow decoder fed the left island then asked
   for one 10 ms concealment frame). Earlier shadow-PLC experiments failed
   when concealing *everything*; concealing exactly one frame between two
   real frames is its design case. Keep whichever wins per-class — the
   architecture fills holes independently, so mixing strategies per hole
   class is free.
5. Unit tests in the existing test style (`SpeechTimeStretcherTests` is the
   template): synthetic sine islands with synthetic counter gaps → assert
   exact output length, phase continuity across fills (no derivative spike
   above threshold at seams), onset non-pre-echo, silence classification.

### B5. Why B is worth doing even if A succeeds

- If A2 fully fixes macOS delivery (~100/s): the reconstructor degrades to
  a pass-through with occasional single-frame concealment (BT interference
  bursts — the 90 ms outlier exists even now) and remains the right shape
  for robustness at range.
- If A5's gamepad-suppression sweep lands mic at ~63/s: holes shrink to
  ≤ 10 ms for two-thirds of misses and the reconstructor output approaches
  transparency.
- If A dead-ends on macOS: B is the product's Bluetooth mode, and the gap
  to the MacBook mic narrows to the irreducible consonant losses plus SWB
  codec character. Every transport improvement then arrives as a free
  quality upgrade with zero further DSP work.

## Direction C: narrowed to one contingency

- **In-band FEC: closed** (measurement 1 — CELT-only packets cannot carry
  LBRR). Remove it from the plan; do not run the `decode_fec` probe.
- **Neural PLC: keep dormant** unless A fails *and* B plateaus below
  acceptance. If ever revived, the correct shape is now precise: a small
  causal concealment model fine-tuned on **this exact loss process** —
  masks sampled from the archived delta histograms (quasi-periodic
  1–2-frame holes at 48 kHz, islands of 1–2 frames), speech from a
  permissive 48 kHz corpus (e.g. VCTK), trained to fill holes given both
  flanks (the anchored architecture supplies exactly that interface),
  exported to Core ML. Weeks of work; license-clean; only justified by a
  measured shortfall. Note the product-level risk this document inherits
  from the dictation use case: a generative filler that *hallucinates
  plausible consonants* can turn soft gaps into confidently wrong words —
  for a dictation product, an audibly soft gap may be the better failure.

## Direction D: the honest boundary, reframed

If A1–A4 conclude that macOS will not service the link faster, the truthful
product statement is not "the controller can't do it" but "**macOS's
Bluetooth power policy caps third-party HID service at ~64 reports/s; the
identical controller delivers ~100 mic frames/s to other hosts.**" Ship:

1. Bluetooth mode with anchored reconstruction, described as "voice-chat
   quality, limited by macOS Bluetooth scheduling";
2. USB-C mode (native DualSense mic) as the full-quality path, already
   automatic when plugged in;
3. a pointer, for enthusiasts, to the open-source DS5Dongle hardware route
   (full-rate mic presented as a USB audio device);
4. the filed Apple Feedback number in the README so users can track it.

## Sequencing and effort

| Step | What | Effort | Decides |
|---|---|---|---|
| 1 | A1b idle-vs-capture tap + live 2 s rate line | ~1 h | Grid is link-wide vs audio-mode-only; enables fast iteration |
| 2 | A1 PacketLogger capture | ~1 h incl. setup | Sniff interval, who initiates, air-truth of 41/s, second-channel check |
| 3 | A2 probes (small-cadence outbound, SDP tickle, ioreg knob) | ~half day | Whether any shippable in-app lever moves the rate |
| 4 | B2 reconstructor + B4 offline harness on 4 archives | ~2–4 days | Bluetooth-mode quality independent of A's outcome |
| 5 | A3 Linux/BlueZ replication + btmon | ~half day | Platform comparison table; falsification path for the link theory |
| 6 | A5 timeboxed sweeps (gamepad suppression, packing watch) | ~half day | Only remaining protocol upside |
| 7 | A4 Apple Feedback with traces; product framing per D | ~2 h | Long-term fix channel |

Steps 3 and 4 are independent and can proceed in parallel; step 4 is the
largest guaranteed quality win under every transport outcome.

## Additions to "do not repeat without a new reason"

- Do not run the Opus `decode_fec` probe — structurally impossible on CELT
  packets (TOC 0xd4).
- Do not flood large 0x39 carriers while the link is (presumed) sniffed —
  multi-ACL outbound competes with inbound anchors and made things worse
  historically; small single-ACL cadence probes only.
- Do not continue sweeping Sony audio-control fields *for delivery rate*
  until A1's trace exists — the dongle's ~100/s in the identical profile
  means rate is not a profile property. (A5's two narrow targets are the
  exception, run with live rate feedback.)
- Do not tune SOLA parameters further — under the anchored design the
  stretcher is retired rather than improved.
- Do not judge any reconstruction change without replaying all four
  archived captures (existing project rule, restated because B replaces
  the whole path).

## The single most important next action

Run the PacketLogger capture (A1). Thirty minutes of setup converts the
central hypothesis of three investigation rounds into two definitive log
lines — the Mode Change interval and the on-air mic packet rate — and every
subsequent engineering and product decision branches cleanly on what those
two lines say.
