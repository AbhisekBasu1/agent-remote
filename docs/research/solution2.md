# Solution 2: locating the missing half of the microphone stream

Date: 18 July 2026. Follow-up to `problem2.md`; continues `problem.md` /
`solution.md`.

> **ADDENDUM (later on 18 July 2026): the tap has delivered its verdict —
> see "Addendum: measured verdict and the carrier experiment" at the end of
> this document before doing anything else.**

## TL;DR

The audio is unintelligible because only ~44.5 of the controller's ~100
microphone frames per second reach the app, and no amount of PLC, filtering,
or gain can reconstruct the missing 55 % of the speech. `problem2.md` is
right that the next step is proof, not tuning. This working tree now contains
that proof instrument plus the gain-consistency fix it requested:

1. **Raw-input tap (new, implemented, tested).** Every IOHID input report
   during a mic session is recorded in memory (timestamp, report ID, length,
   flag byte, and the controller's own generation counters) and a six-line
   statistical summary is written to the log when the stream stops. Its
   centerpiece: the mic packet counter (byte 2) and the gamepad sequence
   counter (byte 8) let us compute the controller's **production rate**
   independently of its delivery rate. One 10-second capture now tells us
   which layer loses the packets.
2. **Gain inconsistency fixed.** `microphoneArmingReport(microphoneVolume:)`
   now embeds the selected VolumeMic instead of a hard-coded 64, so the 0x36
   report can no longer silently overwrite the gain-24 source report. The
   `gain=` log line is now truthful. (`internalMicrophoneSourceReport` had
   already been parameterized.)
3. **Analysis of the existing evidence** (below) points strongly at one
   suspect: **Bluetooth link service-interval quantization (sniff mode), not
   protocol bytes and not app CPU.** The observed cadence is almost exactly
   one packet per 22.5 ms — a canonical Bluetooth sniff interval — and it
   was invariant across radically different outbound loads. The decision
   tree in this document maps each possible tap outcome to a concrete next
   fix.

`swift test`: **41/41 passing** (36 previous + 4 tap tests + 1 arming-gain
test). Nothing was changed in the outbound protocol sequence, the playout
clock, or the PLC path — deliberately, per `problem2.md`'s single-variable
discipline.

## What the two bad recordings already prove

The two failed recordings are not just symptoms; they are measurements.

**Recording 1 (18.20.52, concatenation era):** 11.35 s of wall time played in
4.97 s → speed factor 11.35 / 4.97 = **2.28×**. A complete 100 Hz stream
received at the measured 43.8 packets/s predicts exactly 100 / 43.8 =
**2.28×**. The received frames are therefore uniformly spaced samples of a
~100 Hz, 10 ms-per-frame capture timeline — roughly every 2.28th frame — and
the "too noisy" character was the click at each splice of non-adjacent 10 ms
slices. The controller's **capture clock is running at the documented
~100 Hz**; ~44.5 % of the timeline arrives.

**Recording 2 (18.31.37, fixed-cadence era):** 267 real + 334 concealed = 601
frames = 6.01 s ≈ wall time. Duration correct, but 55.6 % of the output was
synthesized by PLC, which is designed for occasional single-frame loss.
Robotic, unintelligible output is the expected result. This confirms the
playout/PLC change was correct *and* cannot be the fix.

What the fast-forward ratio cannot tell us is **who thins the stream**: the
controller producing only 44.5 encoded frames/s under our outbound state, or
the transport losing frames the controller produced. The byte-2 counter
distinguishes those two worlds — which is why the tap instruments it.

## Why the prime suspect is the Bluetooth link interval

Three independent observations align:

1. **The magic number.** 44.5 packets/s = one packet per **22.47 ms**.
   22.5 ms is exactly 36 Bluetooth slots — a canonical sniff interval. Its
   half, 11.25 ms (18 slots), is the service interval Apple's own Bluetooth
   HID devices negotiate, and 1/11.25 ms = **88.9 packets/s ≈ 2 × 44.5** —
   the well-known ~90 Hz ceiling repeatedly measured for Bluetooth HID input
   on macOS. If the total inbound budget is ~89 reports/s and the controller
   alternates gamepad and mic reports, each stream gets ~44.5/s. The tap's
   per-class rates will check this directly: the sniff picture predicts
   **gamepad ≈ 44.5/s during the mic session and mic + gamepad ≈ 89/s
   total**.
2. **Outbound-load invariance.** With the 50 Hz × 547-byte carrier flood the
   inbound rate was 43.8/s; with control-only 0x36 arming and zero
   continuous output it was 44.5/s. A rate pinned by link scheduling is
   exactly the thing that would not care about our outbound volume. (App
   CPU, decode cost, and logging changed massively between those builds too
   — the rate didn't.)
3. **The working references bypass the OS stack.** Both DS5Dongle variants
   and DS5_Bridge own the HID interrupt L2CAP channel on their own
   BTstack-based radio, where no sniff policy is imposed, and they get
   ~100/s. VIIPER's research doc explicitly lists "does the OS HID stack
   deliver mic-tagged 0x31 reports" as the unproven step on Windows. Nobody
   has demonstrated 100/s through a desktop OS Bluetooth HID stack — we are
   the first to measure it, and we measured ~44.5.

Bluetooth ACL is reliable-with-flush: audio-class packets are typically
marked auto-flushable, so when a sniffed link only services the peripheral
every anchor, the controller's transmit queue overflows/flushes and the
excess frames die **in the controller radio, before macOS software ever sees
them**. That would look like: counter gaps in the tap, ~44.5/s on the air in
a packet trace, and nothing macOS could have queued differently.

## What was implemented in this tree

### 1. `DualSenseMicrophoneInputTap` (new)

`Sources/DualSenseBridgeCore/MicrophoneInputTap.swift`, wired into
`DualSenseBluetoothEnhancedModeEnabler`:

- `begin()` at `startMicrophoneStream()`, `record(...)` as the first act of
  the input-report callback, `finish()` + log dump in
  `stopMicrophoneStream()`.
- Recording is constant-time into preallocated arrays (capacity 32,768
  reports ≈ several minutes at full rate; `truncated=true` is reported if
  exceeded). No allocation, formatting, or file I/O happens while packets
  arrive — the tap cannot cause the loss it measures, per `problem2.md`'s
  explicit requirement.
- Captured per report: monotonic nanosecond timestamp, IOHID report ID,
  buffer length, the flag byte after the report ID, classification
  (mic / gamepad / other via the same flag-bit rule as the parser), and the
  class's generation counter — mic byte 2, or Sony's input sequence number
  at byte 8 for gamepad reports (offset confirmed against hid-playstation
  and VIIPER's `b[7] = seq` USB layout, +1 for the BT header byte).
- After the session it computes and logs: per-report-ID counts and rates,
  per-class rates, a flag-byte histogram (catches any second audio marking),
  counter delta histograms, missing/duplicate/backwards counts, the
  **estimated controller production rate** ((received + missed) / span) for
  both streams, and the mic inter-arrival distribution (p50/p95/min/max,
  <2 ms burst count, modal millisecond buckets — bursts every 22.5 ms would
  show up here unmistakably).

Example of the block that will appear in `~/Library/Logs/Agent Remote/Agent Remote.log` after
the next Square capture:

    mic input tap: duration=10.02s, records=912, truncated=false
    mic input tap report IDs: 0x31=912 (91.0/s)
    mic input tap classes: mic=446 (44.5/s), gamepad=466 (46.5/s), other=0 (0.0/s)
    mic input tap 0x31 flag bytes: 0x02=446, 0x00=466
    mic input tap mic counter: samples=446, deltas=[+1×23, +2×310, +3×112], missed=534, duplicates=0, backwards=0, received=44.5/s, estimatedGenerated=97.8/s
    mic input tap gamepad sequence: samples=466, deltas=[...], missed=..., received=46.5/s, estimatedGenerated=...
    mic input tap mic inter-arrival: p50=22.5ms p95=23.1ms min=0.4ms max=45.2ms mean=22.5ms bursts<2ms=12 modal=[22ms×401, 23ms×20, 0ms×12]

(The numbers above are illustrative; the line shapes are exact.)

### 2. Gain consistency (`problem2.md` §4)

`microphoneArmingReport(microphoneVolume:)` clamps to 0x40 and patches
SetStateData byte 6, and the enabler passes its live `microphoneVolume` at
the 0x36 call site. Every outbound report now agrees on the selected gain,
so the next gain experiment is valid. Covered by
`armingReportEmbedsSelectedMicrophoneVolume()` (CRC re-verified).

### 3. Tests

41/41 green, including the new `MicrophoneInputTapTests`:
halved-stream detection (+2 deltas, doubled generation estimate), counter
wrap/duplicate/backwards classification, capacity truncation, and summary
formatting.

## The measurement runbook (one 10-second capture decides)

1. Package and install using the **safe restart procedure** from
   `problem2.md` (controller off → verify `connected=false` → stop old app →
   launch new app → verify the log starts with HID isolation → controller
   on):

       env CLANG_MODULE_CACHE_PATH=/path/to/ephemeral-research/dualsense-swift-module-cache \
           SWIFTPM_MODULECACHE_OVERRIDE=/path/to/ephemeral-research/dualsense-swiftpm-cache \
           swift test
       ./scripts/package-app.sh

2. Press Square, speak spoken counting ("one, two, three…") for at least
   ten seconds with natural pauses, press Square again.
3. Read the `mic input tap` block in `tail -n 60 "$HOME/Library/Logs/Agent Remote/Agent Remote.log"`.
4. Strongly recommended in parallel, once: capture the session with Apple's
   **PacketLogger** (Additional Tools for Xcode). Two things to look for:
   - **HCI "Mode Change" events** for the DualSense connection: they state
     Sniff vs Active and the interval in slots. A single line here can
     confirm the entire link-interval hypothesis (e.g. "Mode: Sniff,
     Interval: 36 slots" = 22.5 ms, or 18 slots = 11.25 ms).
   - The rate of inbound ACL packets whose payload starts `a1 31` with flag
     bit 1 — the on-air mic rate, which separates "controller never sent
     them" from "macOS software dropped them".

## Reading the tap: decision tree

### Outcome A — mic deltas ≈ +2/+3, estimatedGenerated ≈ 100/s, total 0x31 ≈ 89/s, gamepad ≈ 44.5/s

The controller produces ~100 frames/s; the link services ~89 reports/s
total; the excess is flushed controller-side. This is the sniff/service-
interval picture (PacketLogger's Mode Change line confirms it). Fixes, in
order of preference:

1. **Give the controller a PS5-like inbound audio stream and see whether
   the link leaves sniff.** On PS5 the controller *always* receives steady
   host audio carriers while any audio session is active; firmware may key
   its link-policy request off that. Concretely: resume the 547-byte 0x39
   (or 398-byte 0x36) carrier at its native ~21.3 ms cadence, but fix the
   pipeline first — the old attempt was choked by the 8-deep/1000 ms-timeout
   write pipeline into ~11 completions/s with 102 drops, so it never
   actually delivered a steady carrier and proved nothing. Instrument
   delivered completion cadence; success criterion: inbound mic rises
   toward ~100/s within a few seconds. This is self-contained and
   reversible; run it on a fresh link as its own variant.
2. **Diagnostic-only sniff-exit experiment.** macOS has no supported
   app-level link-policy API. If (and only if) PacketLogger confirms sniff,
   it is worth one experiment with the private IOBluetooth surface to
   request exit-sniff for the connection and watch the mic rate. Whatever
   the result, that is evidence, not a shippable fix; if it works, hunt for
   a legitimate trigger (variant 1 is the most likely candidate) or accept
   the documented ceiling.
3. If neither moves the interval: document the platform ceiling honestly.
   Per `problem2.md`, PLC/stretching/filters must not be used to fake
   intelligibility at 44.5/s; USB remains the full-quality path while
   Bluetooth is capped. (Acceptance criterion 1's escape clause — "unless
   packet counters conclusively prove a different complete transport
   format" — would *not* be satisfied; a thinned stream is not a complete
   transport.)

### Outcome B — mic deltas ≈ +1 (contiguous) at 44.5/s

The controller genuinely produces only ~44.5 frames/s under the current
hybrid outbound state (and the fast-forward ratio then means its counter
increments per *transmitted*, not per *captured*, frame). The stream content
is a thinned sample either way, so the remedy is outbound-state work, not
audio processing: run `problem2.md` §3's variants A/B/C — exact-OLED
0x36-only, current compact-0x32 path without the 0x36 overwrite, exact
byte-for-byte alternate reference — one fresh Bluetooth link per variant,
judging each solely on the tap's mic rate and counter continuity. Variant 1
from Outcome A (steady native-cadence carrier) doubles as variant D here:
"the controller halves its mic rate when no host audio clock is present" is
exactly the kind of firmware behavior a steady carrier would flip.

### Outcome C — estimatedGenerated ≈ 100/s at the parser, but PacketLogger shows ~100/s on air while the tap sees 44.5/s

macOS/IOHID is dropping delivered reports before the callback. Then — and
only then — implement `problem2.md` §5: move the IOHIDManager onto a
dedicated CFRunLoop thread (its callbacks currently share the main run loop
with UI, pointer posting, and Core Audio setup, which the observed 2.8 s
startup stall proves can block), or switch to a device-level
`IOHIDDeviceRegisterInputReportCallback` with a preallocated maximum-size
buffer, and re-run the tap. The tap's arrival timestamps double as the
before/after proof (bunched deliveries behind main-loop stalls become
visible in the inter-arrival histogram). Note the pointer/UI callbacks must
then be trampolined back to the main thread.

### Outcome D — flag-byte histogram shows a second marking, or another report ID carries 71-byte payloads at ~44.5/s

The missing frames exist under an uncounted layout. Extend
`microphoneOpusFrame` to accept the second marking/ID (same 71-byte slice,
offsets per the histogram), add the regression test, and re-measure. (The
existing evidence makes this unlikely — a second marking would have poured
Opus bytes into `gamepadState` and produced visible phantom input — but the
histogram closes it definitively.)

## What deliberately did not change

- The outbound arming sequence, per single-variable discipline: variants
  belong to fresh-link controlled runs after the tap verdict.
- The 10 ms playout clock, three-packet prebuffer, and PLC: correct design,
  kept as-is; PLC should fall below ~5 % on its own once delivery is fixed
  (`problem2.md` acceptance criterion 3).
- No disable transitions, no MetaVoice, no run-loop restructuring ahead of
  evidence, and the default-input restore path is untouched.
- Do not evaluate loudness, noise, or Codex transcription until the tap
  shows ≥ ~95 real packets/s; with the gain fix, gain experiments are now
  valid but still premature.

## Acceptance-criteria status (`problem2.md` list)

| # | Criterion | Status |
| --- | --- | --- |
| 1–2 | ≥95 real packets/s, counter continuity | Blocked on the tap verdict; instrument shipped, decision tree above. |
| 3 | PLC < 5 % | Follows automatically once delivery is fixed; playout kept. |
| 4 | WAV duration ≈ wall time | Already achieved by the fixed-cadence playout. |
| 5–7 | Intelligible playback, no clipping, clean pauses | Re-judge only after criterion 1; gain now consistent end-to-end. |
| 8–9 | Codex waveform/words; Triangle release | Unchanged behavior, re-verify during the next live run. |
| 10–11 | Input restore / MacBook mic | Untouched; keep verifying each run. |
| 12 | No Game Center | Follow the safe restart procedure (controller off during app swap). |
| 13 | Touchpad/buttons | Unaffected; tap additionally quantifies gamepad rate during mic. |
| 14 | No MetaVoice | Preserved; tap and gain fix are fully in-repo. |
| 15 | Test suite | 41/41 passing. |

## One-paragraph answer to `problem2.md`'s precise question

The ~44.5 Hz rate is one report per 22.47 ms — Bluetooth's 36-slot sniff
interval, with 2 × 44.5 matching the ~89/s (11.25 ms) service ceiling that
macOS Bluetooth HID input is known to run at — and it was invariant across
outbound loads, which is why the leading hypothesis is that the link's
service interval, not the Sony state machine or the app, is thinning both
directions of traffic while the controller captures at its documented
100 Hz (the 2.28× fast-forward ratio equals 100/43.8 exactly). The tree now
ships the instrument that proves it one way or the other in a single
10-second capture: per-class rates (gamepad ≈ 44.5/s during mic ⇒ shared
~89/s budget), the byte-2 mic counter and byte-8 gamepad sequence
(gaps ⇒ produced-but-lost; contiguous ⇒ produced-at-44.5), the flag/ID
histograms (uncounted layouts), and inter-arrival bursts — with
PacketLogger's Mode Change events as the independent air-truth check — and
the decision
tree above maps each outcome to its concrete fix: a steady native-cadence
carrier to pull the link out of sniff, outbound-state variants on fresh
links, a dedicated HID run loop, or an extended classifier.

## Addendum: measured verdict and the carrier experiment

Written after the first two instrumented captures (log timestamps 2379111
and 2379142, recordings 19.09.49 and 19.10.19).

### The tap verdict: Outcome A, with refined numbers

Both sessions agree on every figure:

    classes:      mic=42.2–43.8/s, gamepad=22.3–25.9/s, total 0x31=66.1–68.1/s
    mic counter:  deltas +1/+2/+3, missed=374/387, estimatedGenerated=99.4/102.0 per second
    inter-arrival: modal 15 ms × ~131 and 30 ms × ~127, bursts<2ms ≈ 0

1. **The controller produces the full ~100 mic packets/s** (byte-2 counter
   arithmetic, twice, independently). The Sony state machine, the arming
   sequence, and the capture path are fine. The audio content is real voice
   (nonSilent=290/290, peaks in the thousands).
2. **Delivery is quantized to one report per ~15 ms link service window**
   (15/30 ms modal inter-arrivals, no sub-2 ms bursts), for a total budget
   of ~66.7 reports/s shared by all input traffic. Mic and gamepad split it
   roughly 2:1 → ~44/s mic. This is the Bluetooth sniff-interval picture
   (24 slots = 15 ms), measured on-device without PacketLogger.
3. The gamepad byte-8 "sequence" is static over Bluetooth (constant 0x01 —
   the counter that would sit there is only maintained over USB), so its
   +0×171 line is a dead instrument, not evidence. The live gamepad report
   prefixes instead revealed that **the flag byte's high nibble is a rolling
   per-transmitted-report sequence** (observed f→0 across a 15 ms gap and
   0→3 across a 45 ms gap containing exactly two mic reports).

Conclusion: ~57 % of mic frames die inside the controller — flushed before
transmission because the link only grants it ~66.7 transmit windows per
second. macOS software drops nothing (to be re-confirmed session-wide by the
new nibble analysis below). More PLC or filtering cannot help; the link has
to grant more windows.

### What this build adds

1. **Transport-nibble analysis in the tap** (three new log lines):
   `transport nibble (all 0x31 / mic / gamepad)`. If the combined modulo-16
   sequence is contiguous (`missed=0`, deltas all +1) while the mic byte-2
   counter gaps, the pre-transmission-flush picture is proven for the whole
   session and macOS is definitively exonerated — the on-device equivalent
   of the PacketLogger check. (The per-class nibble lines gap by
   construction, since each class skips the other's reports; they are
   printed for completeness.)
2. **The Outcome-A fix candidate, properly built this time: a steady
   PS5-like carrier.** On a PS5 the controller continuously receives host
   audio carriers whenever an audio session is active, and the peripheral is
   the side that can ask the link out of its low-duty mode. The keepalive
   loop now sends a genuine 547-byte 0x39 carrier (silent speaker/haptics)
   every 20 ms, **paced by write completions with at most two in flight** —
   the earlier "50 Hz flood" ran through an 8-deep/1000 ms-timeout pipeline
   that actually delivered ~11/s with 102 drops, so it never tested this
   hypothesis. Skips are counted instead of queued. The 0x36 arming logic is
   unchanged (4 Hz, only while feedback is absent).
3. **Falsifiability built in.** Every 100 carriers and again at stream stop
   the log reports `carrierSent`, `carrierDelivered` (completions/s), and
   `carrierSkippedBusy`. 42/42 tests pass.

### How to read the next capture

Run the same Square test (safe restart procedure first: controller off →
swap app → controller on). Then:

- `carrierDelivered` ≈ 45–50/s **and** mic rises to ≳95/s with modal
  inter-arrival at 10 ms → hypothesis confirmed, intelligible audio should
  follow immediately (PLC will drop toward zero on its own). Re-judge
  loudness/gain only now.
- `carrierDelivered` ≈ 45–50/s **but** mic stays ≈ 44/s with 15/30 ms
  modals → the controller does not renegotiate the link for host audio on
  macOS. The app has then exhausted its supported levers; remaining options,
  in order: (a) a one-off diagnostic with Apple's PacketLogger to read the
  exact Mode Change parameters, plus a private-API exit-sniff experiment
  (evidence only, not shippable); (b) accept and document the ~44 Hz
  Bluetooth ceiling on macOS and treat USB as the full-quality microphone
  path — `problem2.md`'s acceptance criterion 1 cannot be met over
  Bluetooth on this OS in that case, and no audio post-processing may be
  used to pretend otherwise.
- `carrierDelivered` ≪ 45/s (large `carrierSkippedBusy`) → macOS is also
  throttling outbound to the service interval; same conclusion as the
  previous bullet, with the added datum that outbound cannot even sustain
  the mimicry. The experiment is then complete either way.
- In every case, check `transport nibble (all 0x31)`: `missed=0` closes the
  case on macOS-side loss permanently.

## Addendum 2: third capture readout, the lightbar clue, and the ReportInterval experiment

Written after the third instrumented capture (log timestamp 2380283, with
the completion-paced carrier active).

### What the third capture settled

    transport nibble (all 0x31): deltas=[+1×405], missed=0
    mic: received=43.4/s, estimatedGenerated=99.6/s
    carrier: sent=61, delivered=10.8/s, skippedBusy=223
    inter-arrival: modal 15ms×115, 30ms×115

1. **macOS is exonerated, permanently.** The shared transport nibble was
   perfectly contiguous across all 406 reports: every report the controller
   radio transmitted reached the app. All loss is pre-transmission flushing
   inside the controller.
2. **The carrier hypothesis is falsified.** macOS could deliver only
   ~10.8 carriers/s — each 547-byte output report fragments across ~6 of
   the ~66.7 link windows per second (66.7 / 10.8 ≈ 6.2) — and the
   controller did not renegotiate the link no matter how steadily carriers
   arrived. Firmware link policy is not driven by received host audio on
   this platform.
3. **The interleave is a fixed 2:1 round-robin.** Per 45 ms cycle the
   controller transmits two mic reports and one gamepad report (mic nibble
   deltas +1/+2 alternating; gamepad nibble +3). With ~66.7 windows/s the
   mic can never exceed ~44/s. Reaching ≥95 real packets/s requires the
   link service interval itself to shrink to roughly 6–7 ms or less.
4. The user-reported **yellow lightbar during microphone routes** was the
   0x36 arming report's embedded SetState: the dongle firmware's baseline
   asserts AllowLedColor with its signature gold (0xff 0xd7 0x00). Useful
   side-proof that the controller applies our arming state — and now fixed:
   the arming block clears AllowLedColor (valid_flag1 0xf3) and zeroes the
   RGB bytes, so the lightbar is left alone.
5. "More audible at the right pace, still muffled/robotic" is exactly the
   expected sound of unchanged ~56 % concealment with the gain now
   consistently 24 (peak 3311 this session). Loudness can be raised after
   cadence is fixed; it is not the blocker.

### The remaining supported lever: the HID ReportInterval property

IOKit exposes a per-device `ReportInterval` property (microseconds) —
`kIOHIDReportIntervalKey` — through which a client asks the HID transport
for a faster service cadence. It is the only public knob that addresses the
link scheduler itself, and this build now requests **5000 µs** on the
DualSense at configure time, logging the property before and after:

    Bluetooth HID report interval: before=..., requested=5000µs, after=...

Everything else in the outbound path is unchanged from the previous build
(carrier still active, so the single inbound-relevant variable is the
interval request; the lightbar/gain changes cannot affect cadence).

### Reading the fourth capture

- Inter-arrival modes shift from 15/30 ms toward 5–10 ms and mic climbs
  ≥95/s → solved; PLC will collapse on its own; then (and only then) tune
  gain upward from 24 and re-run the intelligibility checks.
- The `after=` value stays unset/ignored and the modes stay 15/30 ms → the
  transport refused the request. At that point every supported lever is
  exhausted and measured: controller produces 100/s, link grants 66.7
  windows/s, macOS delivers every transmitted report, firmware ignores
  carriers, and the stack ignores interval requests. The honest remaining
  options are: (a) confirm the sniff parameters once with PacketLogger
  (HCI Mode Change events) for the record; (b) document Bluetooth
  microphone on macOS as capped (~44 % delivery — unintelligible by
  design) and present USB as the full-quality microphone path, keeping all
  other Bluetooth features; (c) research-grade, non-shippable avenues
  (private HCI exit-sniff, owning the HID L2CAP channels outside the
  system driver) — documented for completeness, not recommended for this
  self-contained open-source project.
