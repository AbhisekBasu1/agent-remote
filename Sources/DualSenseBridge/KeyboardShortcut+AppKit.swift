import AppKit
import ApplicationServices
import DualSenseBridgeCore

extension KeyboardModifiers {
    init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers: KeyboardModifiers = []
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }
        if eventFlags.contains(.function) { modifiers.insert(.function) }
        self = modifiers
    }

    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

extension KeyboardShortcut {
    init(event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            modifiers: KeyboardModifiers(eventFlags: event.modifierFlags),
            keyLabel: ShortcutKeyLabel.label(for: event)
        )
    }
}

private enum ShortcutKeyLabel {
    static func label(for event: NSEvent) -> String {
        if let fixedLabel = fixedLabels[event.keyCode] {
            return fixedLabel
        }

        let characters = event.charactersIgnoringModifiers ?? ""
        let printable = characters.unicodeScalars.filter {
            !$0.properties.isWhitespace
                && $0.value >= 0x20
                && !(0x7F...0x9F).contains($0.value)
        }
        if !printable.isEmpty {
            return String(String.UnicodeScalarView(printable)).uppercased()
        }

        return "Key \(event.keyCode)"
    }

    private static let fixedLabels: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        64: "F17",
        71: "Clear",
        76: "Enter",
        79: "F18",
        80: "F19",
        90: "F20",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        105: "F13",
        106: "F16",
        107: "F14",
        109: "F10",
        111: "F12",
        113: "F15",
        115: "Home",
        116: "Page Up",
        117: "Forward Delete",
        118: "F4",
        119: "End",
        120: "F2",
        121: "Page Down",
        122: "F1",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑"
    ]
}
