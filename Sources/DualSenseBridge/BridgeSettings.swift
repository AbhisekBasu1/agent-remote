import DualSenseBridgeCore
import Foundation

final class BridgeSettings {
    private static let legacyBundleIdentifier = "local.controllerproject.DualSenseBridge"
    private static let legacyMigrationKey = "legacyBundleDefaultsMigrated.v1"
    private static let defaultButtonProfile = ControllerButtonMappingProfile.standard

    private struct StoredShortcut: Codable {
        let shortcut: KeyboardShortcut?
    }

    enum PointerSpeed: Int, CaseIterable {
        case precise = 0
        case balanced = 1
        case fast = 2

        var title: String {
            switch self {
            case .precise: return "Precise"
            case .balanced: return "Balanced"
            case .fast: return "Fast"
            }
        }

        var baseGain: Double {
            switch self {
            case .precise: return 560
            case .balanced: return 820
            case .fast: return 1_120
            }
        }
    }

    enum MicrophoneLevel: Int, CaseIterable {
        case low = 0
        case balanced = 1
        case maximum = 2

        var title: String {
            switch self {
            case .low: return "Low"
            case .balanced: return "Balanced"
            case .maximum: return "Maximum"
            }
        }

        /// DualSense SetState VolumeMic is documented in the 0...64 range.
        /// It is not perceptually linear, so expose useful presets rather
        /// than pretending that a percentage slider would be precise.
        var controllerGain: UInt8 {
            switch self {
            case .low: return 12
            case .balanced: return 24
            case .maximum: return 64
            }
        }
    }

    enum BluetoothMicrophoneSound: Int, CaseIterable {
        case natural = 0
        case sonyVoiceChat = 1
        // One-variable live experiment from the round-4 handoff: identical to
        // Natural except the controller's array beamforming is disabled, to
        // isolate whether residual coloration is created before Opus encoding.
        case naturalNoBeamforming = 2

        var title: String {
            switch self {
            case .natural: return "Natural (Recommended)"
            case .sonyVoiceChat: return "Sony Voice Chat"
            case .naturalNoBeamforming: return "Natural, No Beamforming (Test)"
            }
        }
    }

    enum AgentLightbarColor: Int, CaseIterable {
        case off = 0
        case red = 1
        case amber = 2
        case yellow = 3
        case green = 4
        case cyan = 5
        case blue = 6
        case purple = 7
        case magenta = 8
        case white = 9

        var title: String {
            switch self {
            case .off: return "Off"
            case .red: return "Red"
            case .amber: return "Amber"
            case .yellow: return "Yellow"
            case .green: return "Green"
            case .cyan: return "Cyan"
            case .blue: return "Blue"
            case .purple: return "Purple"
            case .magenta: return "Magenta"
            case .white: return "White"
            }
        }

        var rgb: (red: UInt8, green: UInt8, blue: UInt8) {
            switch self {
            case .off: return (0x00, 0x00, 0x00)
            case .red: return (0xff, 0x14, 0x14)
            case .amber: return (0xff, 0x6a, 0x00)
            case .yellow: return (0xff, 0xd7, 0x00)
            case .green: return (0x00, 0xc0, 0x30)
            case .cyan: return (0x00, 0xb0, 0xb0)
            case .blue: return (0x00, 0x40, 0xff)
            case .purple: return (0x80, 0x20, 0xff)
            case .magenta: return (0xff, 0x20, 0x90)
            case .white: return (0xc8, 0xc8, 0xc8)
            }
        }
    }

    enum AgentHapticStrength: Int, CaseIterable {
        case gentle = 0
        case medium = 1
        case strong = 2

        var title: String {
            switch self {
            case .gentle: return "Gentle"
            case .medium: return "Medium"
            case .strong: return "Strong"
            }
        }

        /// Peak motor amplitudes in the DualSense's 0...255 range. The
        /// low-frequency motor carries the alert; the high-frequency motor
        /// rides along at half so patterns feel crisp rather than mushy.
        var lowFrequencyPeak: UInt8 {
            switch self {
            case .gentle: return 60
            case .medium: return 140
            case .strong: return 255
            }
        }

        var highFrequencyPeak: UInt8 {
            switch self {
            case .gentle: return 30
            case .medium: return 70
            case .strong: return 128
            }
        }
    }

    enum AgentAttentionReminder: Int, CaseIterable {
        case off = 0
        case every15Seconds = 1
        case every30Seconds = 2
        case every60Seconds = 3

        var title: String {
            switch self {
            case .off: return "Off"
            case .every15Seconds: return "Every 15 Seconds"
            case .every30Seconds: return "Every 30 Seconds"
            case .every60Seconds: return "Every Minute"
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .off: return nil
            case .every15Seconds: return 15
            case .every30Seconds: return 30
            case .every60Seconds: return 60
            }
        }
    }

    private enum Key {
        static let enabled = "pointerBridgeEnabled"
        static let pointerSpeed = "pointerSpeed"
        static let naturalScrolling = "naturalScrolling"
        static let rightSideClick = "rightSideClick"
        static let microphoneLevel = "bluetoothMicrophoneLevel"
        static let bluetoothMicrophoneSound = "bluetoothMicrophoneSound"
        static let faceMappingsInitialized = "faceButtonMappingsInitialized"
        static let triangleCodexMappingInitialized = "triangleCodexMappingInitialized.v1"
        static let faceMicrophoneMappingsInitialized = "faceButtonMicrophoneMappingsInitialized.v1"
        static let navigationMappingsInitialized = "navigationMappingsInitialized.v1"
        static let agentLightbarEnabled = "agentLightbarEnabled"
        static let agentHapticsEnabled = "agentHapticsEnabled"
        static let agentHapticStrength = "agentHapticStrength"
        static let agentAttentionReminder = "agentAttentionReminder"
        static let agentPassiveWatchingEnabled = "agentPassiveWatchingEnabled"
        static let agentPlayerLEDsEnabled = "agentPlayerLEDsEnabled"

        static func fleetActionButton(_ action: FleetAction) -> String {
            "fleetActionButton.\(action.rawValue)"
        }

        static func agentLightbarColor(_ event: AgentActivityEvent) -> String {
            "agentLightbarColor.\(event.rawValue)"
        }

        static func agentHapticPattern(_ event: AgentActivityEvent) -> String {
            "agentHapticPattern.\(event.rawValue)"
        }

        // Keep the original key namespace so existing face-button mappings
        // survive the addition of shoulder buttons and triggers.
        static func shortcutButton(_ button: ControllerShortcutButton) -> String {
            "faceButtonShortcut.\(button.storageName)"
        }

        static func shortcutButtonUsesDualSenseMicrophone(_ button: ControllerShortcutButton) -> String {
            "faceButtonUsesDualSenseMicrophone.\(button.storageName)"
        }

    }

    private let defaults: UserDefaults

    /// The public bundle identifier replaces the early local-development
    /// identifier. Copy its persistent values once so existing source-build
    /// users keep mappings and feedback preferences across that transition.
    static func migrateLegacyDefaultsIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        guard defaults.object(forKey: legacyMigrationKey) == nil else { return }
        defer { defaults.set(true, forKey: legacyMigrationKey) }
        guard let legacyValues = defaults.persistentDomain(
            forName: legacyBundleIdentifier
        ) else {
            return
        }
        for (key, value) in legacyValues where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var registeredDefaults: [String: Any] = [
            Key.enabled: true,
            Key.pointerSpeed: PointerSpeed.balanced.rawValue,
            Key.naturalScrolling: true,
            Key.rightSideClick: false,
            Key.microphoneLevel: MicrophoneLevel.balanced.rawValue,
            Key.bluetoothMicrophoneSound: BluetoothMicrophoneSound.natural.rawValue,
            Key.agentLightbarEnabled: true,
            Key.agentHapticsEnabled: true,
            Key.agentHapticStrength: AgentHapticStrength.medium.rawValue,
            Key.agentAttentionReminder: AgentAttentionReminder.off.rawValue,
            Key.agentPassiveWatchingEnabled: true,
            Key.agentPlayerLEDsEnabled: true
        ]
        for (action, button) in Self.defaultButtonProfile.fleetButtons {
            registeredDefaults[Key.fleetActionButton(action)] = button.rawValue
        }
        defaults.register(defaults: registeredDefaults)

        if defaults.object(forKey: Key.faceMappingsInitialized) == nil {
            defaults.set(true, forKey: Key.faceMappingsInitialized)
            setShortcut(Self.defaultButtonProfile.shortcuts[.circle], for: .circle)
        }


        // This one-time migration applies the mapping requested for Codex
        // dictation even when an older build already initialized the buttons.
        if defaults.object(forKey: Key.triangleCodexMappingInitialized) == nil {
            defaults.set(true, forKey: Key.triangleCodexMappingInitialized)
            setShortcut(Self.defaultButtonProfile.shortcuts[.triangle], for: .triangle)
        }

        if defaults.object(forKey: Key.faceMicrophoneMappingsInitialized) == nil {
            defaults.set(true, forKey: Key.faceMicrophoneMappingsInitialized)
            setUsesDualSenseMicrophone(
                Self.defaultButtonProfile.microphoneButtons.contains(.triangle),
                for: .triangle
            )
        }

        // The field-tested navigation layout ships as the default: bumpers
        // step panes/windows (⌘[ ⌘]), triggers step tabs (⌘⇧[ ⌘⇧]), Square
        // cancels, and the left stick pages terminal scrollback (fn-arrows).
        // Existing user mappings are never overwritten; the d-pad, Cross,
        // and stick clicks stay deliberately free for fleet actions.
        if defaults.object(forKey: Key.navigationMappingsInitialized) == nil {
            defaults.set(true, forKey: Key.navigationMappingsInitialized)
            applyNavigationDefaults(overwritingExisting: false)
        }
    }

    private func applyNavigationDefaults(overwritingExisting: Bool) {
        for (button, defaultShortcut) in Self.defaultButtonProfile.shortcuts
        where button != .triangle && button != .circle {
            if overwritingExisting || shortcut(for: button) == nil {
                setShortcut(defaultShortcut, for: button)
            }
        }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var pointerSpeed: PointerSpeed {
        get {
            PointerSpeed(rawValue: defaults.integer(forKey: Key.pointerSpeed)) ?? .balanced
        }
        set { defaults.set(newValue.rawValue, forKey: Key.pointerSpeed) }
    }

    var naturalScrolling: Bool {
        get { defaults.bool(forKey: Key.naturalScrolling) }
        set { defaults.set(newValue, forKey: Key.naturalScrolling) }
    }

    var rightSideClickEnabled: Bool {
        get { defaults.bool(forKey: Key.rightSideClick) }
        set { defaults.set(newValue, forKey: Key.rightSideClick) }
    }

    var microphoneLevel: MicrophoneLevel {
        get {
            MicrophoneLevel(rawValue: defaults.integer(forKey: Key.microphoneLevel))
                ?? .balanced
        }
        set { defaults.set(newValue.rawValue, forKey: Key.microphoneLevel) }
    }

    var bluetoothMicrophoneSound: BluetoothMicrophoneSound {
        get {
            BluetoothMicrophoneSound(
                rawValue: defaults.integer(forKey: Key.bluetoothMicrophoneSound)
            ) ?? .natural
        }
        set { defaults.set(newValue.rawValue, forKey: Key.bluetoothMicrophoneSound) }
    }

    var agentLightbarEnabled: Bool {
        get { defaults.bool(forKey: Key.agentLightbarEnabled) }
        set { defaults.set(newValue, forKey: Key.agentLightbarEnabled) }
    }

    var agentHapticsEnabled: Bool {
        get { defaults.bool(forKey: Key.agentHapticsEnabled) }
        set { defaults.set(newValue, forKey: Key.agentHapticsEnabled) }
    }

    var agentHapticStrength: AgentHapticStrength {
        get {
            AgentHapticStrength(
                rawValue: defaults.integer(forKey: Key.agentHapticStrength)
            ) ?? .medium
        }
        set { defaults.set(newValue.rawValue, forKey: Key.agentHapticStrength) }
    }

    var agentAttentionReminder: AgentAttentionReminder {
        get {
            AgentAttentionReminder(
                rawValue: defaults.integer(forKey: Key.agentAttentionReminder)
            ) ?? .off
        }
        set { defaults.set(newValue.rawValue, forKey: Key.agentAttentionReminder) }
    }

    var agentPassiveWatchingEnabled: Bool {
        get { defaults.bool(forKey: Key.agentPassiveWatchingEnabled) }
        set { defaults.set(newValue, forKey: Key.agentPassiveWatchingEnabled) }
    }

    var agentPlayerLEDsEnabled: Bool {
        get { defaults.bool(forKey: Key.agentPlayerLEDsEnabled) }
        set { defaults.set(newValue, forKey: Key.agentPlayerLEDsEnabled) }
    }

    /// -1 stored means the action is unbound.
    func fleetButton(for action: FleetAction) -> ControllerShortcutButton? {
        guard let stored = defaults.object(
            forKey: Key.fleetActionButton(action)
        ) as? Int else {
            return nil
        }
        return ControllerShortcutButton(rawValue: stored)
    }

    func setFleetButton(
        _ button: ControllerShortcutButton?,
        for action: FleetAction
    ) {
        defaults.set(button?.rawValue ?? -1, forKey: Key.fleetActionButton(action))
    }

    /// Assigns one semantic action to one controller button. Any Fleet action
    /// previously owned by that button is released; reassigning an action
    /// automatically removes it from its former button because each action
    /// stores exactly one owner.
    func assignFleetAction(
        _ action: FleetAction?,
        to button: ControllerShortcutButton
    ) {
        if let previousAction = fleetAction(boundTo: button),
           previousAction != action {
            setFleetButton(nil, for: previousAction)
        }
        if let action {
            setFleetButton(button, for: action)
        }
    }

    /// A button bound to a fleet action wins over its keystroke mapping, so
    /// a fleet control can never leak a keystroke into the focused app.
    func fleetAction(boundTo button: ControllerShortcutButton) -> FleetAction? {
        FleetAction.allCases.first { fleetButton(for: $0) == button }
    }

    func agentLightbarColor(for event: AgentActivityEvent) -> AgentLightbarColor {
        guard let stored = defaults.object(
            forKey: Key.agentLightbarColor(event)
        ) as? Int,
        let color = AgentLightbarColor(rawValue: stored) else {
            return Self.defaultAgentLightbarColor(for: event)
        }
        return color
    }

    func setAgentLightbarColor(
        _ color: AgentLightbarColor,
        for event: AgentActivityEvent
    ) {
        defaults.set(color.rawValue, forKey: Key.agentLightbarColor(event))
    }

    func agentHapticPattern(for event: AgentActivityEvent) -> AgentHapticPatternKind {
        guard let stored = defaults.object(
            forKey: Key.agentHapticPattern(event)
        ) as? Int,
        let pattern = AgentHapticPatternKind(rawValue: stored) else {
            return Self.defaultAgentHapticPattern(for: event)
        }
        return pattern
    }

    func setAgentHapticPattern(
        _ pattern: AgentHapticPatternKind,
        for event: AgentActivityEvent
    ) {
        defaults.set(pattern.rawValue, forKey: Key.agentHapticPattern(event))
    }

    static func defaultAgentLightbarColor(
        for event: AgentActivityEvent
    ) -> AgentLightbarColor {
        switch event {
        case .working: return .purple
        case .attention: return .amber
        case .done: return .green
        case .error: return .red
        case .idle: return .off
        }
    }

    static func defaultAgentHapticPattern(
        for event: AgentActivityEvent
    ) -> AgentHapticPatternKind {
        switch event {
        case .working: return .none
        case .attention: return .doubleTap
        case .done: return .tap
        case .error: return .buzz
        case .idle: return .none
        }
    }

    func shortcut(for button: ControllerShortcutButton) -> KeyboardShortcut? {
        guard let data = defaults.data(forKey: Key.shortcutButton(button)),
              let stored = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return nil
        }
        return stored.shortcut
    }

    func setShortcut(_ shortcut: KeyboardShortcut?, for button: ControllerShortcutButton) {
        let stored = StoredShortcut(shortcut: shortcut)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Key.shortcutButton(button))
    }

    func usesDualSenseMicrophone(for button: ControllerShortcutButton) -> Bool {
        defaults.bool(forKey: Key.shortcutButtonUsesDualSenseMicrophone(button))
    }

    func setUsesDualSenseMicrophone(_ enabled: Bool, for button: ControllerShortcutButton) {
        defaults.set(enabled, forKey: Key.shortcutButtonUsesDualSenseMicrophone(button))
    }

    func resetButtonMappings() {
        for button in ControllerShortcutButton.allCases {
            setShortcut(nil, for: button)
            setUsesDualSenseMicrophone(false, for: button)
        }
        for action in FleetAction.allCases {
            setFleetButton(nil, for: action)
        }
        for (button, shortcut) in Self.defaultButtonProfile.shortcuts {
            setShortcut(shortcut, for: button)
        }
        for button in Self.defaultButtonProfile.microphoneButtons {
            setUsesDualSenseMicrophone(true, for: button)
        }
        for (action, button) in Self.defaultButtonProfile.fleetButtons {
            setFleetButton(button, for: action)
        }
    }
}
