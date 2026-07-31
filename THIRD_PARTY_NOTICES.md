# Third-party notices

Agent Remote is MIT-licensed, but it includes or adapts work under additional
permissive terms. The corresponding license texts are shipped in every app
bundle.

## Distributed components

### Apple NullAudio sample

`Driver/DualSenseBridgeMic.c` began from Apple's NullAudio Core Audio sample
and contains substantial Agent Remote modifications. Apple's original 2013
sample-code terms are retained in `Driver/LICENSE-APPLE.txt` and packaged as
`AudioDriver-APPLE-LICENSE.txt`.

### Opus

Bluetooth voice decoding dynamically loads `libopus.0.dylib`. Packaging copies
the library from the selected Homebrew Opus installation; the exact package
version and target architecture are recorded in `BUILD-COMPONENTS.txt` inside
the app. The redistributable license is retained in
`ThirdParty/Opus/LICENSE` and packaged as `Opus-LICENSE.txt`.

Upstream: <https://opus-codec.org/>

### Sonic

The vendored `Sources/CSonic/sonic.c` and `Sources/CSonic/include/sonic.h` are
Bill Cox's Sonic library, copyright 2010, licensed under Apache-2.0. The license
is retained in `ThirdParty/Sonic/LICENSE` and packaged as
`Sonic-APACHE-LICENSE.txt`.

Upstream: <https://github.com/waywardgeek/sonic>

### yabai technique

`MacOSWorkspaceSwitcher.swift` adapts the Dock gesture-event technique used by
yabai. No yabai executable is bundled or installed. Åsmund Vikane's MIT notice
is retained in `ThirdParty/Yabai/LICENSE` and packaged as
`Yabai-MIT-LICENSE.txt`.

Upstream reference: <https://github.com/asmvik/yabai/blob/master/src/space_manager.c>

## Protocol research references

The Bluetooth HID report layout and microphone arming work were informed by
open-source controller implementations and documentation. These projects are
not bundled dependencies; they are cited so the origin of the protocol
research remains auditable:

- awalol/DS5Dongle: <https://github.com/awalol/DS5Dongle> (MIT)
- MarcelineVPQ/DS5Dongle-OLED-Edition:
  <https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition> (MIT)
- Linux `hid-playstation`:
  <https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c>
- hbashton/VIIPER: <https://github.com/hbashton/VIIPER>

When updating a vendored component or adapting additional implementation code,
record the upstream revision, preserve its copyright notice, and update both
this document and the packaged licenses.
