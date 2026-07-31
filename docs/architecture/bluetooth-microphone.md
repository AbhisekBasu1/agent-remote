# Agent Remote: I turned a PS5 controller into a remote control for coding agents

On July 15, OpenAI shipped its first hardware product: [Codex Micro](https://www.tomshardware.com/peripherals/keyboards/openais-first-hardware-device-is-an-rgb-macropod-codex-micro-features-13-low-profile-keys-and-a-joystick-for-controlling-ai-coding-agents), a $230 limited-run macropad for supervising coding agents — thirteen keys, a joystick, a rotary dial that adjusts reasoning effort, and six RGB "Agent Keys" that show live agent status. It sold as a scarcity drop, and it validated something I'd already been building for weeks: coding agents deserve a physical control surface.

Here's the thing, though. There's a device with more buttons, two analog sticks, a full touchpad, an RGB light bar, dual rumble motors, a microphone array, and a speaker — and there's a decent chance it's already in a drawer next to your desk. Sony has shipped over 50 million of them.

**Agent Remote** is a small native macOS menu-bar app that turns a DualSense into that control surface:

- The **light bar shows your agent's state** — purple while it works, amber when it needs your approval, green when it's done, red on failure. Glanceable from the couch, across the room, with the laptop lid barely open.
- The **controller taps your hands** when an agent needs you. A double-tap for "waiting on approval," a single tap for "turn complete," a long buzz for errors — patterns, strength, and a repeating reminder are all configurable from the menu bar.
- **Hold Triangle and talk to Codex** — push-to-talk dictation through the *controller's own microphone*, including over Bluetooth, which macOS does not support at all. More on that; it's most of this post.
- The **touchpad is a full trackpad**: pointer, tap to click, two-finger scroll, drag, and two-finger swipe to switch macOS Spaces. You can supervise a fleet of terminal sessions without touching a mouse.
- All **19 buttons plus eight stick directions** map to arbitrary keys and shortcuts. Cross for Enter, dpad through history, whatever fits your harness.

It integrates with Codex CLI via its `notify` hook and with Claude Code via lifecycle hooks — both installable from a menu item — and any other tool can drive it with a one-line shell command. MIT licensed, no third-party services, no virtual-cable purchases; everything ships in the bundle.

The button mapping and trackpad emulation are honest engineering but not novel. Two parts of this project are, I think, genuinely new: getting the DualSense microphone to work over Bluetooth on macOS at all, and what I learned about *why* it can never be perfect there. That story took four investigation rounds, and each round's villain was different.

## Sony hides an audio device inside a game controller

Plug a DualSense in over USB-C and it's a normal Core Audio microphone. Pair it over Bluetooth and the microphone simply does not exist as far as macOS is concerned. It isn't A2DP, it isn't HFP — Sony runs voice as a proprietary **Opus-over-HID** stream on the same channel as the gamepad reports.

The receive side looks like this: input report `0x31` — the same report ID that carries stick positions and button states — has a flag byte right after the report ID. Bit 1 marks the report as audio. When it's set, the payload is a 71-byte Opus frame (CELT-only, super-wideband, 10 ms, stereo, ~57 kbit/s), about 100 of them per second. When it's clear, it's a regular gamepad report. One report ID, two protocols, distinguished by one bit.

The transmit side is stranger. Output reports are protected by Sony's CRC-32 variant (standard polynomial, seeded with an extra `0xa2` prefix byte — get it wrong and the controller silently ignores you). Arming the mic takes a specific dance: clear the hardware mute latch with a minimal state report, select the internal microphone array and its DSP mode, send a compact stream-enable, and — on some firmware — a 398-byte `0x36` report carrying a full 63-byte known-good `SetStateData` block, because a sparse "just the fields I want" version is accepted by HID and then ignored by the controller. Once armed, the stream is *sticky*: there is no documented stop command. You stop listening; you do not tell it to stop talking.

And because audio frames share report `0x31` with gamepad input, the moment the mic streams, macOS's GameController framework starts interpreting compressed audio bytes as controller input. My favorite failure mode of the entire project: encoded speech would randomly parse as presses of the PS button, and **Game Center would launch over my terminal, summoned by the sound of my own voice.** The fix is to seize the HID device exclusively (IOKit `kIOHIDOptionsTypeSeizeDevice`) for the app's lifetime and re-implement gamepad parsing from the raw reports — which is also why the app has its own complete touchpad/button pipeline instead of leaning on GameController.

Credit where due: the flag-bit layout and arming sequence were established by the open-source [DS5Dongle](https://github.com/awalol/DS5Dongle) family of projects, which run the controller from a $10 Pico W. What follows is where this project had to go beyond them, because they never had to fight a desktop OS.

## Round 1: the filter that only let silence through

First live test: everything armed, frames flowing, decoder running — and every decoded frame was digital silence. Eighteen frames in three seconds, all peak zero. I spent days sweeping Sony's DSP profiles (there are at least eight AudioControl combinations) and every one "failed identically."

That identical failure was the clue. The app's classifier decided "this report is audio" by checking that the payload began `d4 ff` — copied from a hardware trace. I benchmarked the exact encoder configuration against the app's own bundled libopus, and the result explained everything:

| Encoder input | Packet starts with |
|---|---|
| Digital silence | `d4 ff fe 00 00 …` |
| Actual speech | `d4 6b 59 58 99 …` |

`d4` is the Opus TOC byte. `ff fe` is the CELT range coder emitting its *silence* symbol. In other words, `d4 ff` is the signature of **encoded silence** — and a real voice frame has an `ff` second byte with probability of roughly 1/256. The classifier passed silence with probability one and speech with probability zero. The controller had been streaming my voice the whole time; the app was measuring its own filter. Every "failed" DSP experiment had been testing nothing.

The fix is the one both working reference implementations use: classify by the flag bit, never by content. It also fixed a latent input bug — a left stick held near 82 % deflection puts `0xd4` in an axis byte, and the old content-sniffing classifier had been silently eating those gamepad reports.

Lesson one, stated plainly: **when every experiment fails identically, stop varying the transmitter and audit the receiver.**

## Round 2: the case of the missing 57 %

With the filter fixed, voice decoded — sped up 2.28× and unintelligible. That number was itself the next clue: the controller captures 100 frames per second, and 100 ÷ 43.8 (the measured arrival rate) = 2.28. The frames that arrived were perfectly timed samples of a complete recording. Something was thinning the stream by more than half.

I built a zero-allocation instrumentation tap — every HID input report timestamped into preallocated arrays, with statistics computed only after the session, so the instrument could not cause the loss it measured. Three facts fell out:

1. **The controller produces the full ~100 frames/s.** The mic packets carry a rolling counter; arithmetic across its gaps gives the production rate independent of the delivery rate. Measured: 99.4–102 frames generated per second, every session.
2. **macOS delivers every report the controller transmits.** There's a second, subtler counter — the high nibble of the flag byte rolls per *transmitted* report across both traffic classes. It arrived perfectly contiguous: +1, 406 times in a row. Nothing was lost between the controller's radio and my callback.
3. **Arrivals sit on a ~15 ms grid.** Modal inter-arrival times of 15 ms and 30 ms, no sub-2 ms bursts, roughly 66 report slots per second shared 2:1 between mic and gamepad traffic.

Put together: the frames die *inside the controller, before transmission*. macOS parks Bluetooth Classic HID links in a power-saving service schedule (the ~15 ms grid is a textbook sniff interval; Apple's own input devices are designed around 11.25–15 ms), the controller only gets ~66 transmit windows a second, and its firmware flushes the backlog and sends the newest frame each window. The DS5Dongle hardware receives ~100/s from the *same controller with the same bytes* because its BTstack radio rejects sniff mode outright.

I falsified the tempting fixes so you don't have to: flooding PS5-style 547-byte audio carriers at the controller doesn't make firmware renegotiate the link (macOS fragments them across ~6 windows each, making things worse), and IOKit's public `kIOHIDReportIntervalKey` request is accepted and ignored — it configures polling transports, not Bluetooth link policy. There is no supported per-link QoS knob for an unprivileged macOS app. The next step on this track is a PacketLogger HCI trace to read the Mode Change events for the record, then an Apple Feedback with the evidence.

A side clue from this round that mattered later: mid-investigation, the light bar turned *gold* during captures. The borrowed arming state asserted `AllowLedColor` with the dongle project's signature color — proof the controller applies exactly the state you send, and the origin of a rule this project now treats as law: **LED ownership and audio state live in separate reports with disjoint validity bits.** Mixing them once correlated with the controller returning encoded silence.

## Rounds 3 and 4: reconstruction, measured instead of vibed

If only 43 % of frames can arrive, the remaining question is what to do with them. The counter gives every received frame an exact true-time address, and the loss pattern is not "58 % missing" — it's 10–20 ms holes between exactly-placed islands of real audio, re-anchored every ~32 ms. Also settled: the packets are CELT-only, so Opus in-band FEC is structurally impossible (LBRR exists only in SILK/hybrid modes). No flag will turn redundancy on.

I stopped trusting my ears alone and built an offline lab: replay archived captures through the exact live decode path, render candidate reconstructions, and score each against a *simultaneous MacBook-microphone recording* of the same utterance using Whisper word-edit distance. Fourteen archived takes, 459 reference words, one number per idea.

The scoreboard was humbling. Phase-aligned crossfaded seams at every hole junction: **worse** (174 edits vs. the 108 baseline) — at 43 % survival, real samples are the scarcest resource, and seam alignment spends them. A transient-protected allocator that stretched vowels more and consonants less: **worse** (125–138) — time-stretchers want a steady rate, and counter-paced correction dumps timing debt exactly where the signal is least reliable. Channel-lane experiments on the controller's stereo stream: near-duplicate lanes (0.95 correlation), no win available. What survived four rounds of attempted cleverness is almost embarrassingly simple: uniform fixed-ratio pitch-preserving expansion (Bill Cox's Sonic library) of channel 0, with the ratio learned per session. Every structural "improvement" I was sure about lost to it on the archives.

So the honest status today: **over USB the controller is a full-quality native microphone. Over Bluetooth, dictation works and is bounded by macOS link policy** — voice-chat grade, reconstructed from ~43 % of frames, with the measurement harness (and a 108-edit gate any future approach must beat) committed to the repo. I'd rather ship that sentence than a demo that only works with a cable hidden off-camera.

## Then the easy part: making the agent physical

Compared to the microphone, the agent-feedback layer was a joy, and it's built directly on the protocol discipline the mic work forced.

**Output.** The light bar uses the LED-only report proven safe during audio bring-up — `AllowLedColor` valid, every audio and mute bit invalid — so a status color can never corrupt a microphone route. Haptics use Sony's classic rumble emulation (`HapticsSelect | CompatibleVibration`, two motor bytes), with one interlock: rumble is suppressed while the Bluetooth mic streams, because switching haptics modes mid-capture is exactly the kind of state disturbance that cost me a week in round 1. Patterns are sparse edge lists ending in an explicit zero — rumble is sticky between reports, and a cancelled pattern must never strand the motors on. All of it works across three connection paths: seized Bluetooth HID, seized USB HID, and a GameController-framework fallback (GCDeviceLight + CoreHaptics) when isolation isn't available.

**Input events.** Agents report state through the dumbest transport I could get away with: a spool directory. A bundled POSIX-sh helper writes a four-line `key=value` file and atomically renames it in; the app watches the directory with a dispatch source. No socket server, no daemon, nothing a hook can block on, and events survive an app restart. Claude Code's lifecycle hooks (`UserPromptSubmit` → working, `Notification` → attention, `Stop` → done, `SessionEnd` → idle) and Codex CLI's `notify` program both install from a menu item — with JSON/TOML merges that preserve your existing config and back it up first. Anything else is one shell line:

```sh
"…/Agent Remote.app/Contents/Resources/agent-remote-event" attention my-ci-script
```

The result is the loop I wanted back when this was a mapping utility: agent runs, light bar glows purple; it hits a permission prompt, the controller double-taps in my hands and turns amber; I glance at the screen, press Cross to approve; it finishes, single tap, green, fading back to idle. Hold Triangle, *say* the next task through the controller, release. The laptop is across the room. It feels less like using a computer and more like holding a leash.

## What's next

- A **PacketLogger capture and Linux/BlueZ control run** to close the Bluetooth transport question on the record, and an Apple Feedback asking for a QoS opt-out for high-rate HID devices. The same controller delivers 100 % of frames to a $10 microcontroller; macOS deserves parity.
- An **MCP server** exposing the controller as tools (`haptic.pulse`, `lightbar.set`, `await_button`, push-to-talk), so any agent can acquire a body without bespoke hook wiring — and so other peripherals can join it.
- More harnesses, more devices, whatever the issues ask for.

Agent Remote is MIT-licensed and self-contained — bundled Opus decode, a project-owned virtual audio driver grown from Apple's NullAudio sample, vendored Sonic, and a SIP-friendly Spaces-switching technique adapted from yabai. It stands on the shoulders of the DS5Dongle projects and the Linux `hid-playstation` driver, and on fourteen archived recordings of me counting to ten into a game controller, over and over, for science.

OpenAI is right that agents want dedicated physical controls. I just think the best agent peripheral of 2026 might be the one Sony accidentally shipped in 2020.
