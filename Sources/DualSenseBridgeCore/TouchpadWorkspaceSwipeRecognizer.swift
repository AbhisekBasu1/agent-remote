import Foundation

/// The direction the user's two fingers travel across the touchpad. macOS
/// moves to the Space on the opposite screen edge, so a leftward finger swipe
/// corresponds to Control-Right and vice versa.
public enum WorkspaceSwipeDirection: Equatable, Sendable {
    case left
    case right

    public var macOSSpaceShortcut: KeyboardShortcut {
        switch self {
        case .left:
            return .controlRightArrow
        case .right:
            return .controlLeftArrow
        }
    }
}

public enum WorkspaceSwipeButtonTransition: Equatable, Sendable {
    case ignored
    case began
    case endedAsRightClick
    case endedAfterSwipe
    case endedCancelled
}

/// Recognizes the DualSense substitute for a Mac three-finger horizontal
/// swipe: place two fingers down, physically hold the touchpad, then move both
/// fingers left or right. Requiring both contacts to travel in the same
/// direction prevents a pinch or one-finger adjustment from switching Spaces.
public struct TouchpadWorkspaceSwipeRecognizer: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var contactFreshness: TimeInterval
        public var horizontalDistance: Double
        public var minimumIndividualDistance: Double
        public var horizontalDominanceRatio: Double
        public var clickMovementTolerance: Double

        public init(
            contactFreshness: TimeInterval = 0.25,
            horizontalDistance: Double = 0.22,
            minimumIndividualDistance: Double = 0.14,
            horizontalDominanceRatio: Double = 1.25,
            clickMovementTolerance: Double = 0.06
        ) {
            self.contactFreshness = contactFreshness
            self.horizontalDistance = horizontalDistance
            self.minimumIndividualDistance = minimumIndividualDistance
            self.horizontalDominanceRatio = horizontalDominanceRatio
            self.clickMovementTolerance = clickMovementTolerance
        }
    }

    private struct Contact: Sendable {
        let x: Double
        let y: Double
        let timestamp: TimeInterval
    }

    private struct TrackingSession: Sendable {
        let primaryStart: Contact
        let secondaryStart: Contact
        var maximumObservedTravel = 0.0
        var didTrigger = false
    }

    public var configuration: Configuration

    private var primaryContact: Contact?
    private var secondaryContact: Contact?
    private var trackingSession: TrackingSession?

    public var isTracking: Bool {
        trackingSession != nil
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func primaryChanged(
        x: Double,
        y: Double,
        isActive: Bool,
        at timestamp: TimeInterval
    ) -> WorkspaceSwipeDirection? {
        primaryContact = isActive
            ? Contact(x: x, y: y, timestamp: timestamp)
            : nil
        return recognizeSwipe()
    }

    public mutating func secondaryChanged(
        x: Double,
        y: Double,
        isActive: Bool,
        at timestamp: TimeInterval
    ) -> WorkspaceSwipeDirection? {
        secondaryContact = isActive
            ? Contact(x: x, y: y, timestamp: timestamp)
            : nil
        return recognizeSwipe()
    }

    public mutating func touchpadButtonChanged(
        pressed: Bool,
        at timestamp: TimeInterval
    ) -> WorkspaceSwipeButtonTransition {
        if pressed {
            guard trackingSession == nil,
                  let primaryContact,
                  let secondaryContact,
                  isFresh(primaryContact, at: timestamp),
                  isFresh(secondaryContact, at: timestamp) else {
                return .ignored
            }

            trackingSession = TrackingSession(
                primaryStart: primaryContact,
                secondaryStart: secondaryContact
            )
            return .began
        }

        guard let completed = trackingSession else {
            return .ignored
        }
        trackingSession = nil

        if completed.didTrigger {
            return .endedAfterSwipe
        }
        if completed.maximumObservedTravel <= configuration.clickMovementTolerance {
            return .endedAsRightClick
        }
        return .endedCancelled
    }

    public mutating func reset() {
        primaryContact = nil
        secondaryContact = nil
        trackingSession = nil
    }

    private mutating func recognizeSwipe() -> WorkspaceSwipeDirection? {
        guard var trackingSession,
              !trackingSession.didTrigger,
              let primaryContact,
              let secondaryContact else {
            return nil
        }

        let primaryDeltaX = primaryContact.x - trackingSession.primaryStart.x
        let secondaryDeltaX = secondaryContact.x - trackingSession.secondaryStart.x
        let centroidDeltaX = (primaryDeltaX + secondaryDeltaX) / 2
        let centroidDeltaY = (
            (primaryContact.y - trackingSession.primaryStart.y)
                + (secondaryContact.y - trackingSession.secondaryStart.y)
        ) / 2
        let primaryDeltaY = primaryContact.y - trackingSession.primaryStart.y
        let secondaryDeltaY = secondaryContact.y - trackingSession.secondaryStart.y

        trackingSession.maximumObservedTravel = max(
            trackingSession.maximumObservedTravel,
            hypot(centroidDeltaX, centroidDeltaY),
            hypot(primaryDeltaX, primaryDeltaY),
            hypot(secondaryDeltaX, secondaryDeltaY)
        )

        let bothMoveLeft = primaryDeltaX < 0 && secondaryDeltaX < 0
        let bothMoveRight = primaryDeltaX > 0 && secondaryDeltaX > 0
        let minimumIndividualTravel = min(
            abs(primaryDeltaX),
            abs(secondaryDeltaX)
        )
        let isHorizontal = abs(centroidDeltaX)
            >= abs(centroidDeltaY) * configuration.horizontalDominanceRatio

        guard (bothMoveLeft || bothMoveRight),
              minimumIndividualTravel >= configuration.minimumIndividualDistance,
              abs(centroidDeltaX) >= configuration.horizontalDistance,
              isHorizontal else {
            self.trackingSession = trackingSession
            return nil
        }

        trackingSession.didTrigger = true
        self.trackingSession = trackingSession
        return centroidDeltaX < 0 ? .left : .right
    }

    private func isFresh(_ contact: Contact, at timestamp: TimeInterval) -> Bool {
        let age = timestamp - contact.timestamp
        return age >= 0 && age <= configuration.contactFreshness
    }
}
