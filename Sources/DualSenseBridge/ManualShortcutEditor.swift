import AppKit
import DualSenseBridgeCore

enum ManualShortcutEditor {
    private struct KeyChoice {
        let keyCode: UInt16
        let label: String
    }

    static func present(
        for button: ControllerShortcutButton,
        currentShortcut: KeyboardShortcut?,
        parentWindow: NSWindow,
        onSave: @escaping (KeyboardShortcut) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Choose Shortcut for \(button.title)"
        alert.informativeText = "Pick the key and modifiers directly. This works even when another app intercepts the shortcut system-wide."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let keyPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        var choices = keyChoices
        if let currentShortcut,
           !choices.contains(where: { $0.keyCode == currentShortcut.keyCode }) {
            choices.insert(
                KeyChoice(keyCode: currentShortcut.keyCode, label: currentShortcut.keyLabel),
                at: 0
            )
        }
        for choice in choices {
            let item = NSMenuItem(title: choice.label, action: nil, keyEquivalent: "")
            item.tag = Int(choice.keyCode)
            keyPicker.menu?.addItem(item)
        }
        if let currentShortcut {
            keyPicker.selectItem(withTag: Int(currentShortcut.keyCode))
        } else {
            keyPicker.selectItem(withTag: 0)
        }

        let command = modifierCheckbox(title: "Command ⌘", enabled: currentShortcut?.modifiers.contains(.command) == true)
        let option = modifierCheckbox(title: "Option ⌥", enabled: currentShortcut?.modifiers.contains(.option) == true)
        let control = modifierCheckbox(title: "Control ⌃", enabled: currentShortcut?.modifiers.contains(.control) == true)
        let shift = modifierCheckbox(title: "Shift ⇧", enabled: currentShortcut?.modifiers.contains(.shift) == true)
        let function = modifierCheckbox(title: "Fn", enabled: currentShortcut?.modifiers.contains(.function) == true)

        let keyLabel = NSTextField(labelWithString: "Key:")
        keyLabel.alignment = .right
        keyLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        keyPicker.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let keyRow = NSStackView(views: [keyLabel, keyPicker])
        keyRow.orientation = .horizontal
        keyRow.alignment = .centerY
        keyRow.spacing = 10

        let modifierLabel = NSTextField(labelWithString: "Modifiers:")
        modifierLabel.alignment = .right
        modifierLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let modifierChoices = NSStackView(views: [command, option, control, shift, function])
        modifierChoices.orientation = .horizontal
        modifierChoices.alignment = .centerY
        modifierChoices.spacing = 8
        let modifierRow = NSStackView(views: [modifierLabel, modifierChoices])
        modifierRow.orientation = .horizontal
        modifierRow.alignment = .centerY
        modifierRow.spacing = 10

        let stack = NSStackView(views: [keyRow, modifierRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 76))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: accessory.bottomAnchor, constant: -4)
        ])
        alert.accessoryView = accessory

        alert.beginSheetModal(for: parentWindow) { response in
            guard response == .alertFirstButtonReturn,
                  let selectedItem = keyPicker.selectedItem else {
                return
            }

            var modifiers: KeyboardModifiers = []
            if command.state == .on { modifiers.insert(.command) }
            if option.state == .on { modifiers.insert(.option) }
            if control.state == .on { modifiers.insert(.control) }
            if shift.state == .on { modifiers.insert(.shift) }
            if function.state == .on { modifiers.insert(.function) }

            onSave(KeyboardShortcut(
                keyCode: UInt16(selectedItem.tag),
                modifiers: modifiers,
                keyLabel: selectedItem.title
            ))
        }
    }

    private static func modifierCheckbox(title: String, enabled: Bool) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        checkbox.state = enabled ? .on : .off
        return checkbox
    }

    private static let keyChoices: [KeyChoice] = [
        KeyChoice(keyCode: 0, label: "A"),
        KeyChoice(keyCode: 11, label: "B"),
        KeyChoice(keyCode: 8, label: "C"),
        KeyChoice(keyCode: 2, label: "D"),
        KeyChoice(keyCode: 14, label: "E"),
        KeyChoice(keyCode: 3, label: "F"),
        KeyChoice(keyCode: 5, label: "G"),
        KeyChoice(keyCode: 4, label: "H"),
        KeyChoice(keyCode: 34, label: "I"),
        KeyChoice(keyCode: 38, label: "J"),
        KeyChoice(keyCode: 40, label: "K"),
        KeyChoice(keyCode: 37, label: "L"),
        KeyChoice(keyCode: 46, label: "M"),
        KeyChoice(keyCode: 45, label: "N"),
        KeyChoice(keyCode: 31, label: "O"),
        KeyChoice(keyCode: 35, label: "P"),
        KeyChoice(keyCode: 12, label: "Q"),
        KeyChoice(keyCode: 15, label: "R"),
        KeyChoice(keyCode: 1, label: "S"),
        KeyChoice(keyCode: 17, label: "T"),
        KeyChoice(keyCode: 32, label: "U"),
        KeyChoice(keyCode: 9, label: "V"),
        KeyChoice(keyCode: 13, label: "W"),
        KeyChoice(keyCode: 7, label: "X"),
        KeyChoice(keyCode: 16, label: "Y"),
        KeyChoice(keyCode: 6, label: "Z"),
        KeyChoice(keyCode: 29, label: "0"),
        KeyChoice(keyCode: 18, label: "1"),
        KeyChoice(keyCode: 19, label: "2"),
        KeyChoice(keyCode: 20, label: "3"),
        KeyChoice(keyCode: 21, label: "4"),
        KeyChoice(keyCode: 23, label: "5"),
        KeyChoice(keyCode: 22, label: "6"),
        KeyChoice(keyCode: 26, label: "7"),
        KeyChoice(keyCode: 28, label: "8"),
        KeyChoice(keyCode: 25, label: "9"),
        KeyChoice(keyCode: 49, label: "Space"),
        KeyChoice(keyCode: 36, label: "Return"),
        KeyChoice(keyCode: 48, label: "Tab"),
        KeyChoice(keyCode: 51, label: "Delete"),
        KeyChoice(keyCode: 53, label: "Escape"),
        KeyChoice(keyCode: 123, label: "←"),
        KeyChoice(keyCode: 124, label: "→"),
        KeyChoice(keyCode: 125, label: "↓"),
        KeyChoice(keyCode: 126, label: "↑"),
        KeyChoice(keyCode: 122, label: "F1"),
        KeyChoice(keyCode: 120, label: "F2"),
        KeyChoice(keyCode: 99, label: "F3"),
        KeyChoice(keyCode: 118, label: "F4"),
        KeyChoice(keyCode: 96, label: "F5"),
        KeyChoice(keyCode: 97, label: "F6"),
        KeyChoice(keyCode: 98, label: "F7"),
        KeyChoice(keyCode: 100, label: "F8"),
        KeyChoice(keyCode: 101, label: "F9"),
        KeyChoice(keyCode: 109, label: "F10"),
        KeyChoice(keyCode: 103, label: "F11"),
        KeyChoice(keyCode: 111, label: "F12")
    ]
}
