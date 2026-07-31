import AppKit
import DualSenseBridgeCore

final class ShortcutRecorderButton: NSButton {
    var shortcut: KeyboardShortcut? {
        didSet { updateTitle() }
    }

    var onShortcutChanged: ((KeyboardShortcut?) -> Void)?

    private let emptyTitle: String
    private var isRecordingShortcut = false

    init(shortcut: KeyboardShortcut?, emptyTitle: String = "Not Set") {
        self.shortcut = shortcut
        self.emptyTitle = emptyTitle
        super.init(frame: .zero)

        target = self
        action = #selector(beginRecording)
        bezelStyle = .rounded
        alignment = .center
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        toolTip = "Click, then press a key or modifier combination. Click elsewhere to cancel."
        setAccessibilityLabel("Keyboard shortcut")
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }

        guard !event.isARepeat else { return }
        let newShortcut = KeyboardShortcut(event: event)
        shortcut = newShortcut
        onShortcutChanged?(newShortcut)
        finishRecording()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.flagsChanged(with: event)
            return
        }

        let modifiers = KeyboardModifiers(eventFlags: event.modifierFlags)
        title = modifiers.isEmpty ? "Press shortcut…" : modifiers.displayPrefix + "…"
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign, isRecordingShortcut {
            isRecordingShortcut = false
            updateTitle()
        }
        return didResign
    }

    @objc private func beginRecording() {
        isRecordingShortcut = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    private func finishRecording() {
        isRecordingShortcut = false
        updateTitle()
        window?.makeFirstResponder(nil)
    }

    private func updateTitle() {
        guard !isRecordingShortcut else { return }
        title = shortcut?.displayText ?? emptyTitle
        contentTintColor = shortcut == nil ? .secondaryLabelColor : .labelColor
        setAccessibilityValue(shortcut?.displayText ?? emptyTitle)
    }
}
