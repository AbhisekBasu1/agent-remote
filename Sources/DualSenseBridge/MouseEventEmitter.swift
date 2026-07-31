import AppKit
import ApplicationServices
import DualSenseBridgeCore

final class MouseEventEmitter {
    private struct ClickRecord {
        let button: BridgeMouseButton
        let location: CGPoint
        let timestamp: TimeInterval
        let count: Int64
    }

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var heldButton: BridgeMouseButton?
    private var heldClickCount: Int64?
    private var lastClick: ClickRecord?
    private var cursorIntegrator = CursorIntegrator()
    private var moveEventCount = 0
    private var didLogAccessibilityFailure = false

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityAccess(showPrompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: showPrompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func move(normalizedDeltaX: Double, normalizedDeltaY: Double, baseGain: Double) {
        guard isAccessibilityTrusted else {
            if !didLogAccessibilityFailure {
                DiagnosticLog.write("mouse events rejected: accessibility not trusted")
                didLogAccessibilityFailure = true
            }
            return
        }
        didLogAccessibilityFailure = false

        let magnitude = hypot(normalizedDeltaX, normalizedDeltaY)
        let acceleration = 0.58 + min(magnitude / 0.10, 1.0) * 0.72
        let deltaX = normalizedDeltaX * baseGain * acceleration
        let deltaY = -normalizedDeltaY * baseGain * acceleration

        let actual = currentQuartzMouseLocation()
        let now = ProcessInfo.processInfo.systemUptime
        let integrated = cursorIntegrator.destination(
            actualX: actual.x,
            actualY: actual.y,
            deltaX: deltaX * 1.12,
            deltaY: deltaY,
            at: now
        )
        let unconstrainedDestination = CGPoint(x: integrated.x, y: integrated.y)
        let destination = constrainedToActiveDisplays(unconstrainedDestination)
        cursorIntegrator.synchronize(
            x: destination.x,
            y: destination.y,
            at: now
        )
        moveEventCount += 1
        if moveEventCount <= 12 || moveEventCount.isMultiple(of: 100) {
            DiagnosticLog.write(
                "mouse move #\(moveEventCount) normalized=(\(normalizedDeltaX),\(normalizedDeltaY)) destination=(\(destination.x),\(destination.y))"
            )
        }

        let type: CGEventType
        let cgButton: CGMouseButton
        switch heldButton {
        case .left:
            type = .leftMouseDragged
            cgButton = .left
        case .right:
            type = .rightMouseDragged
            cgButton = .right
        case nil:
            type = .mouseMoved
            cgButton = .left
        }

        CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: destination,
            mouseButton: cgButton
        )?.post(tap: .cghidEventTap)
    }

    func scroll(
        normalizedDeltaX: Double,
        normalizedDeltaY: Double,
        natural: Bool
    ) {
        guard isAccessibilityTrusted else { return }

        let direction = natural ? -1.0 : 1.0
        let scrollGain = 420.0
        let vertical = Int32((normalizedDeltaY * scrollGain * direction).rounded())
        let horizontal = Int32((normalizedDeltaX * scrollGain * direction).rounded())
        guard vertical != 0 || horizontal != 0 else { return }

        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else { return }

        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    func setButton(_ button: BridgeMouseButton, pressed: Bool) {
        guard isAccessibilityTrusted else { return }

        let location = currentQuartzMouseLocation()
        let clickCount: Int64
        if pressed {
            guard heldButton == nil else { return }
            heldButton = button
            clickCount = nextClickCount(
                for: button,
                at: location,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
            heldClickCount = clickCount
        } else {
            guard heldButton == button else { return }
            heldButton = nil
            clickCount = heldClickCount ?? 1
            heldClickCount = nil
        }

        let type: CGEventType = switch (button, pressed) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        }

        let cgButton: CGMouseButton = button == .left ? .left : .right
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: cgButton
        )
        event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event?.post(tap: .cghidEventTap)
    }

    func click(_ button: BridgeMouseButton) {
        guard isAccessibilityTrusted, heldButton == nil else { return }

        let location = currentQuartzMouseLocation()
        let count = nextClickCount(
            for: button,
            at: location,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        let cgButton: CGMouseButton = button == .left ? .left : .right
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        for type in [downType, upType] {
            let event = CGEvent(
                mouseEventSource: eventSource,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: cgButton
            )
            event?.setIntegerValueField(.mouseEventClickState, value: count)
            event?.post(tap: .cghidEventTap)
        }
    }

    func setKeyboardShortcut(_ shortcut: KeyboardShortcut, pressed: Bool) {
        guard isAccessibilityTrusted else { return }
        for step in shortcut.chordEvents(pressed: pressed) {
            let event = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: CGKeyCode(step.keyCode),
                keyDown: step.keyDown
            )
            if step.isModifier {
                event?.type = .flagsChanged
            }
            event?.flags = step.modifiers.cgEventFlags
            event?.post(tap: .cghidEventTap)
        }
    }

    func pressKeyboardShortcut(_ shortcut: KeyboardShortcut) {
        setKeyboardShortcut(shortcut, pressed: true)
        setKeyboardShortcut(shortcut, pressed: false)
    }

    /// Emits the repeated primary-key event generated by a held hardware key.
    /// Modifier keys stay physically down from the original chord press and
    /// are released only when the controller direction returns to center.
    func repeatKeyboardShortcut(_ shortcut: KeyboardShortcut) {
        guard isAccessibilityTrusted else { return }
        let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: CGKeyCode(shortcut.keyCode),
            keyDown: true
        )
        event?.flags = shortcut.modifiers.cgEventFlags
        event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        event?.post(tap: .cghidEventTap)
    }

    func releaseAnyHeldInputs() {
        if let heldButton {
            setButton(heldButton, pressed: false)
        }
        cursorIntegrator.reset()
    }

    private func nextClickCount(
        for button: BridgeMouseButton,
        at location: CGPoint,
        timestamp: TimeInterval
    ) -> Int64 {
        let count: Int64
        if let lastClick,
           lastClick.button == button,
           timestamp >= lastClick.timestamp,
           timestamp - lastClick.timestamp <= NSEvent.doubleClickInterval,
           hypot(location.x - lastClick.location.x, location.y - lastClick.location.y) <= 5 {
            count = min(lastClick.count + 1, 3)
        } else {
            count = 1
        }

        lastClick = ClickRecord(
            button: button,
            location: location,
            timestamp: timestamp,
            count: count
        )
        return count
    }

    private func currentQuartzMouseLocation() -> CGPoint {
        if let location = CGEvent(source: nil)?.location {
            return location
        }

        let cocoaLocation = NSEvent.mouseLocation
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: cocoaLocation.x, y: primaryScreenTop - cocoaLocation.y)
    }

    /// Core Graphics permits coordinates outside a display when events are
    /// posted rapidly, while the visible cursor is clamped by WindowServer.
    /// Constrain our accumulated position too, otherwise it can drift far past
    /// an edge and appear to jump when input resumes.
    private func constrainedToActiveDisplays(_ point: CGPoint) -> CGPoint {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return point
        }

        var displays = [CGDirectDisplayID](
            repeating: CGMainDisplayID(),
            count: Int(displayCount)
        )
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return point
        }

        let bounds = displays.prefix(Int(displayCount)).map(CGDisplayBounds)
        if bounds.contains(where: { $0.contains(point) }) {
            return point
        }

        var nearestPoint = point
        var nearestSquaredDistance = CGFloat.greatestFiniteMagnitude

        for displayBounds in bounds {
            // CGRect's maximum edge is exclusive. Staying one subpixel inside
            // avoids repeatedly posting a position just beyond the display.
            let maximumX = max(displayBounds.minX, displayBounds.maxX.nextDown)
            let maximumY = max(displayBounds.minY, displayBounds.maxY.nextDown)
            let candidate = CGPoint(
                x: min(max(point.x, displayBounds.minX), maximumX),
                y: min(max(point.y, displayBounds.minY), maximumY)
            )
            let deltaX = candidate.x - point.x
            let deltaY = candidate.y - point.y
            let squaredDistance = deltaX * deltaX + deltaY * deltaY
            if squaredDistance < nearestSquaredDistance {
                nearestSquaredDistance = squaredDistance
                nearestPoint = candidate
            }
        }

        return nearestPoint
    }
}
