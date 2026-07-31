import Foundation

public enum ControllerShortcutButton: Int, CaseIterable, Codable, Hashable, Sendable {
    case triangle
    case square
    case cross
    case circle
    case l1
    case l2
    case r1
    case r2
    case dpadUp
    case dpadRight
    case dpadDown
    case dpadLeft
    case l3
    case r3
    case create
    case options
    case playStation
    case touchpadClick
    case mute
    case leftStickUp
    case leftStickRight
    case leftStickDown
    case leftStickLeft
    case rightStickUp
    case rightStickRight
    case rightStickDown
    case rightStickLeft

    public var title: String {
        switch self {
        case .triangle: return "Triangle"
        case .square: return "Square"
        case .cross: return "Cross (X)"
        case .circle: return "Circle"
        case .l1: return "L1"
        case .l2: return "L2"
        case .r1: return "R1"
        case .r2: return "R2"
        case .dpadUp: return "D-pad Up"
        case .dpadRight: return "D-pad Right"
        case .dpadDown: return "D-pad Down"
        case .dpadLeft: return "D-pad Left"
        case .l3: return "L3 (Left Stick Click)"
        case .r3: return "R3 (Right Stick Click)"
        case .create: return "Create"
        case .options: return "Options"
        case .playStation: return "PS Button"
        case .touchpadClick: return "Touchpad Click"
        case .mute: return "Mute Button"
        case .leftStickUp: return "Left Stick Up"
        case .leftStickRight: return "Left Stick Right"
        case .leftStickDown: return "Left Stick Down"
        case .leftStickLeft: return "Left Stick Left"
        case .rightStickUp: return "Right Stick Up"
        case .rightStickRight: return "Right Stick Right"
        case .rightStickDown: return "Right Stick Down"
        case .rightStickLeft: return "Right Stick Left"
        }
    }

    public var storageName: String {
        switch self {
        case .triangle: return "triangle"
        case .square: return "square"
        case .cross: return "cross"
        case .circle: return "circle"
        case .l1: return "l1"
        case .l2: return "l2"
        case .r1: return "r1"
        case .r2: return "r2"
        case .dpadUp: return "dpadUp"
        case .dpadRight: return "dpadRight"
        case .dpadDown: return "dpadDown"
        case .dpadLeft: return "dpadLeft"
        case .l3: return "l3"
        case .r3: return "r3"
        case .create: return "create"
        case .options: return "options"
        case .playStation: return "playStation"
        case .touchpadClick: return "touchpadClick"
        case .mute: return "mute"
        case .leftStickUp: return "leftStickUp"
        case .leftStickRight: return "leftStickRight"
        case .leftStickDown: return "leftStickDown"
        case .leftStickLeft: return "leftStickLeft"
        case .rightStickUp: return "rightStickUp"
        case .rightStickRight: return "rightStickRight"
        case .rightStickDown: return "rightStickDown"
        case .rightStickLeft: return "rightStickLeft"
        }
    }

    /// Analog stick directions behave like held keyboard directions. Physical
    /// controller buttons remain edge-driven so hold-to-talk and one-shot
    /// shortcuts are never retriggered unexpectedly.
    public var repeatsWhileHeld: Bool {
        switch self {
        case .leftStickUp, .leftStickRight, .leftStickDown, .leftStickLeft,
             .rightStickUp, .rightStickRight, .rightStickDown, .rightStickLeft:
            return true
        default:
            return false
        }
    }
}

/// Converts an analog trigger value into stable button down/up edges. Separate
/// press and release thresholds prevent tiny movements around the boundary
/// from repeatedly firing a mapped shortcut.
public struct AnalogTriggerLatch: Equatable, Sendable {
    public let pressThreshold: UInt8
    public let releaseThreshold: UInt8
    public private(set) var isPressed = false

    public init(
        pressThreshold: UInt8 = 128,
        releaseThreshold: UInt8 = 96
    ) {
        precondition(releaseThreshold < pressThreshold)
        self.pressThreshold = pressThreshold
        self.releaseThreshold = releaseThreshold
    }

    /// Returns a new pressed state only when the logical state changes.
    public mutating func update(value: UInt8) -> Bool? {
        if !isPressed, value >= pressThreshold {
            isPressed = true
            return true
        }
        if isPressed, value <= releaseThreshold {
            isPressed = false
            return false
        }
        return nil
    }

    public mutating func reset() {
        isPressed = false
    }
}

public struct AnalogAxisDirectionUpdate: Equatable, Sendable {
    public let negativePressed: Bool?
    public let positivePressed: Bool?

    public init(negativePressed: Bool?, positivePressed: Bool?) {
        self.negativePressed = negativePressed
        self.positivePressed = positivePressed
    }
}

/// Turns one centered analog axis into two stable virtual buttons. A direction
/// presses only after a deliberate movement and releases closer to center,
/// preventing stick drift from chattering keyboard shortcuts.
public struct AnalogAxisDirectionLatch: Equatable, Sendable {
    public let pressDistance: UInt8
    public let releaseDistance: UInt8
    public private(set) var isNegativePressed = false
    public private(set) var isPositivePressed = false

    public init(
        pressDistance: UInt8 = 64,
        releaseDistance: UInt8 = 40
    ) {
        precondition(pressDistance <= 127)
        precondition(releaseDistance < pressDistance)
        self.pressDistance = pressDistance
        self.releaseDistance = releaseDistance
    }

    public mutating func update(value: UInt8) -> AnalogAxisDirectionUpdate {
        let distance = Int(value) - 128
        var negativeEdge: Bool?
        var positiveEdge: Bool?

        if !isNegativePressed, distance <= -Int(pressDistance) {
            isNegativePressed = true
            negativeEdge = true
        } else if isNegativePressed, distance >= -Int(releaseDistance) {
            isNegativePressed = false
            negativeEdge = false
        }

        if !isPositivePressed, distance >= Int(pressDistance) {
            isPositivePressed = true
            positiveEdge = true
        } else if isPositivePressed, distance <= Int(releaseDistance) {
            isPositivePressed = false
            positiveEdge = false
        }

        return AnalogAxisDirectionUpdate(
            negativePressed: negativeEdge,
            positivePressed: positiveEdge
        )
    }

    public mutating func reset() {
        isNegativePressed = false
        isPositivePressed = false
    }
}

public struct KeyboardModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = KeyboardModifiers(rawValue: 1 << 0)
    public static let option = KeyboardModifiers(rawValue: 1 << 1)
    public static let control = KeyboardModifiers(rawValue: 1 << 2)
    public static let shift = KeyboardModifiers(rawValue: 1 << 3)
    public static let function = KeyboardModifiers(rawValue: 1 << 4)

    public var displayPrefix: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        if contains(.function) { result += "fn " }
        return result
    }
}

public struct KeyboardShortcut: Hashable, Codable, Sendable {
    public let keyCode: UInt16
    public let modifiers: KeyboardModifiers
    public let keyLabel: String

    public init(
        keyCode: UInt16,
        modifiers: KeyboardModifiers = [],
        keyLabel: String
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var displayText: String {
        modifiers.displayPrefix + keyLabel
    }

    /// Produces a complete physical-style key chord. A flags-only synthetic
    /// event is enough for many apps, but hold-to-talk listeners commonly wait
    /// for the modifier key itself to be released.
    public func chordEvents(pressed: Bool) -> [KeyboardChordEvent] {
        let modifierKeys: [(modifier: KeyboardModifiers, keyCode: UInt16)] = [
            (.control, 59),
            (.option, 58),
            (.shift, 56),
            (.command, 55),
            (.function, 63)
        ]
        let activeModifierKeys = modifierKeys.filter { modifiers.contains($0.modifier) }

        if pressed {
            var activeModifiers: KeyboardModifiers = []
            var events: [KeyboardChordEvent] = []
            for modifierKey in activeModifierKeys {
                activeModifiers.insert(modifierKey.modifier)
                events.append(KeyboardChordEvent(
                    keyCode: modifierKey.keyCode,
                    modifiers: activeModifiers,
                    keyDown: true,
                    isModifier: true
                ))
            }
            events.append(KeyboardChordEvent(
                keyCode: keyCode,
                modifiers: modifiers,
                keyDown: true
            ))
            return events
        }

        var activeModifiers = modifiers
        var events = [KeyboardChordEvent(
            keyCode: keyCode,
            modifiers: activeModifiers,
            keyDown: false
        )]
        for modifierKey in activeModifierKeys.reversed() {
            activeModifiers.remove(modifierKey.modifier)
            events.append(KeyboardChordEvent(
                keyCode: modifierKey.keyCode,
                modifiers: activeModifiers,
                keyDown: false,
                isModifier: true
            ))
        }
        return events
    }

    public static let returnKey = KeyboardShortcut(
        keyCode: 36,
        keyLabel: "Return"
    )

    /// Command-O is Codex's system-wide speech-to-text shortcut. Keeping the
    /// virtual key code here lets the bridge configure it without asking the
    /// user to press a shortcut that Codex intercepts globally.
    public static let commandO = KeyboardShortcut(
        keyCode: 31,
        modifiers: .command,
        keyLabel: "O"
    )

    public static let controlLeftArrow = KeyboardShortcut(
        keyCode: 123,
        modifiers: .control,
        keyLabel: "←"
    )

    public static let controlRightArrow = KeyboardShortcut(
        keyCode: 124,
        modifiers: .control,
        keyLabel: "→"
    )
}

public struct KeyboardChordEvent: Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: KeyboardModifiers
    public let keyDown: Bool
    public let isModifier: Bool

    public init(
        keyCode: UInt16,
        modifiers: KeyboardModifiers,
        keyDown: Bool,
        isModifier: Bool = false
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyDown = keyDown
        self.isModifier = isModifier
    }
}
