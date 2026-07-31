import CoreGraphics
import DualSenseBridgeCore

/// Emits the Dock's native horizontal-space gesture rather than a keyboard
/// shortcut. This mirrors a real Mac trackpad swipe, works independently of
/// the user's Mission Control key bindings, and needs no AppleScript or extra
/// Automation permission.
///
/// The event-field technique is adapted from yabai's SIP-compatible Space
/// focus implementation:
/// https://github.com/asmvik/yabai/blob/master/src/space_manager.c
/// yabai is MIT licensed; its notice is bundled with the app.
final class MacOSWorkspaceSwitcher {
    private enum DockGesture {
        static let eventType = CGEventField(rawValue: 55)!
        static let hidType = CGEventField(rawValue: 110)!
        static let swipeMotion = CGEventField(rawValue: 123)!
        static let swipeProgress = CGEventField(rawValue: 124)!
        static let velocityX = CGEventField(rawValue: 129)!
        static let phase = CGEventField(rawValue: 132)!

        static let dockControl: Int64 = 30
        static let dockSwipe: Int64 = 23
        static let horizontalMotion: Int64 = 1
        static let began: Int64 = 1
        static let ended: Int64 = 4
        static let highVelocity = 9_999.0
    }

    @discardableResult
    func switchSpace(for direction: WorkspaceSwipeDirection) -> Bool {
        guard let event = CGEvent(source: nil) else { return false }

        // A leftward finger swipe reveals the Space to the right. Dock's
        // progress sign describes the destination direction, not the finger
        // direction.
        let destinationSign = direction == .left ? 1.0 : -1.0
        event.setIntegerValueField(DockGesture.eventType, value: DockGesture.dockControl)
        event.setIntegerValueField(DockGesture.hidType, value: DockGesture.dockSwipe)
        event.setIntegerValueField(DockGesture.swipeMotion, value: DockGesture.horizontalMotion)
        event.setDoubleValueField(DockGesture.swipeProgress, value: destinationSign)
        event.setDoubleValueField(
            DockGesture.velocityX,
            value: destinationSign * DockGesture.highVelocity
        )

        event.setIntegerValueField(DockGesture.phase, value: DockGesture.began)
        event.post(tap: .cgSessionEventTap)
        event.setIntegerValueField(DockGesture.phase, value: DockGesture.ended)
        event.post(tap: .cgSessionEventTap)
        return true
    }
}
