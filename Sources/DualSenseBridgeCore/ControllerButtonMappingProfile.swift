import Foundation

/// Semantic controller actions that operate on Agent Remote's live session
/// fleet instead of emitting a keyboard shortcut.
public enum FleetAction: Int, CaseIterable, Hashable, Sendable {
    case focusPrevious = 0
    case focusNext = 1
    case raiseFocused = 2

    public var title: String {
        switch self {
        case .focusPrevious: return "Focus Previous Session"
        case .focusNext: return "Focus Next Session"
        case .raiseFocused: return "Raise Focused Session"
        }
    }
}

/// One complete, user-restorable controller layout. Keeping the shipped
/// profile in the pure core module gives first launch, Restore Defaults, UI,
/// and tests one source of truth.
public struct ControllerButtonMappingProfile: Equatable, Sendable {
    public let shortcuts: [ControllerShortcutButton: KeyboardShortcut]
    public let microphoneButtons: Set<ControllerShortcutButton>
    public let fleetButtons: [FleetAction: ControllerShortcutButton]

    public init(
        shortcuts: [ControllerShortcutButton: KeyboardShortcut],
        microphoneButtons: Set<ControllerShortcutButton>,
        fleetButtons: [FleetAction: ControllerShortcutButton]
    ) {
        self.shortcuts = shortcuts
        self.microphoneButtons = microphoneButtons
        self.fleetButtons = fleetButtons
    }

    /// The field-tested layout used by the maintainer and shipped to every
    /// new installation.
    public static let standard = ControllerButtonMappingProfile(
        shortcuts: [
            .triangle: .commandO,
            .square: KeyboardShortcut(keyCode: 53, keyLabel: "Escape"),
            .circle: .returnKey,
            .l1: KeyboardShortcut(
                keyCode: 33,
                modifiers: .command,
                keyLabel: "["
            ),
            .l2: KeyboardShortcut(
                keyCode: 33,
                modifiers: [.command, .shift],
                keyLabel: "{"
            ),
            .r1: KeyboardShortcut(
                keyCode: 30,
                modifiers: .command,
                keyLabel: "]"
            ),
            .r2: KeyboardShortcut(
                keyCode: 30,
                modifiers: [.command, .shift],
                keyLabel: "}"
            ),
            .leftStickUp: KeyboardShortcut(
                keyCode: 126,
                modifiers: .function,
                keyLabel: "↑"
            ),
            .leftStickRight: KeyboardShortcut(
                keyCode: 124,
                modifiers: .function,
                keyLabel: "→"
            ),
            .leftStickDown: KeyboardShortcut(
                keyCode: 125,
                modifiers: .function,
                keyLabel: "↓"
            ),
            .leftStickLeft: KeyboardShortcut(
                keyCode: 123,
                modifiers: .function,
                keyLabel: "←"
            )
        ],
        microphoneButtons: [.triangle],
        fleetButtons: [
            .focusPrevious: .dpadLeft,
            .focusNext: .dpadRight,
            .raiseFocused: .dpadUp
        ]
    )
}
