import Foundation

public enum BridgeMouseButton: Equatable, Sendable {
    case left
    case right
}

public enum GestureAction: Equatable, Sendable {
    case move(deltaX: Double, deltaY: Double)
    case scroll(deltaX: Double, deltaY: Double)
}

public struct TapCandidate: Equatable, Sendable {
    public let id: UInt64
    public let button: BridgeMouseButton
    public let delay: TimeInterval

    public init(id: UInt64, button: BridgeMouseButton, delay: TimeInterval) {
        self.id = id
        self.button = button
        self.delay = delay
    }
}

/// Recognizes one- and two-finger taps from the legacy DualSense touchpad
/// coordinates exposed by GameController. That profile has no explicit touch
/// state, so a short debounce distinguishes a real lift from passing through
/// the touch surface's neutral coordinate during a swipe.
public struct TouchpadTapRecognizer: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var maximumDuration: TimeInterval
        public var maximumNormalizedTravel: Double
        public var maximumNormalizedJump: Double
        public var releaseDebounce: TimeInterval

        public init(
            maximumDuration: TimeInterval = 0.30,
            maximumNormalizedTravel: Double = 0.055,
            maximumNormalizedJump: Double = 0.22,
            releaseDebounce: TimeInterval = 0.020
        ) {
            self.maximumDuration = maximumDuration
            self.maximumNormalizedTravel = maximumNormalizedTravel
            self.maximumNormalizedJump = maximumNormalizedJump
            self.releaseDebounce = releaseDebounce
        }
    }

    private enum ContactSlot {
        case primary
        case secondary
    }

    private struct Contact: Sendable {
        var lastX: Double
        var lastY: Double
        var totalTravel: Double = 0
        var awaitingAxisInitialization: Bool
        var hasPendingAxisReset = false
    }

    private struct Session: Sendable {
        let startedAt: TimeInterval
        var sawPrimary: Bool
        var sawSecondary: Bool
        var isCancelled: Bool
    }

    public var configuration: Configuration

    private var primaryContact: Contact?
    private var secondaryContact: Contact?
    private var session: Session?
    private var pendingTap: TapCandidate?
    private var nextTapID: UInt64 = 0
    private var lastSessionEndedAt: TimeInterval?
    private var lastSessionWasCancelled = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func primaryChanged(
        x: Double,
        y: Double,
        at timestamp: TimeInterval
    ) -> TapCandidate? {
        contactChanged(slot: .primary, x: x, y: y, at: timestamp)
    }

    public mutating func secondaryChanged(
        x: Double,
        y: Double,
        at timestamp: TimeInterval
    ) -> TapCandidate? {
        contactChanged(slot: .secondary, x: x, y: y, at: timestamp)
    }

    public mutating func touchpadButtonChanged(pressed: Bool) {
        guard pressed else { return }
        session?.isCancelled = true
        pendingTap = nil
    }

    public mutating func consumePendingTap(id: UInt64) -> BridgeMouseButton? {
        guard pendingTap?.id == id else { return nil }
        let button = pendingTap?.button
        pendingTap = nil
        return button
    }

    public mutating func reset() {
        primaryContact = nil
        secondaryContact = nil
        session = nil
        pendingTap = nil
        lastSessionEndedAt = nil
        lastSessionWasCancelled = false
    }

    private mutating func contactChanged(
        slot: ContactSlot,
        x: Double,
        y: Double,
        at timestamp: TimeInterval
    ) -> TapCandidate? {
        if x == 0 && y == 0 {
            return finishContact(slot: slot, at: timestamp)
        }

        if contact(for: slot) == nil {
            beginContact(slot: slot, x: x, y: y, at: timestamp)
            return nil
        }

        updateContact(slot: slot, x: x, y: y)
        return nil
    }

    private mutating func beginContact(
        slot: ContactSlot,
        x: Double,
        y: Double,
        at timestamp: TimeInterval
    ) {
        if session == nil {
            var inheritsCancellation = false
            if let lastSessionEndedAt {
                let elapsed = timestamp - lastSessionEndedAt
                if elapsed >= 0 && elapsed <= configuration.releaseDebounce {
                    // A new coordinate arriving immediately after neutral means
                    // the finger crossed the centre rather than lifted.
                    pendingTap = nil
                    inheritsCancellation = lastSessionWasCancelled
                }
            }

            session = Session(
                startedAt: timestamp,
                sawPrimary: slot == .primary,
                sawSecondary: slot == .secondary,
                isCancelled: inheritsCancellation
            )
        } else {
            if slot == .primary {
                session?.sawPrimary = true
            } else {
                session?.sawSecondary = true
            }
        }

        setContact(
            Contact(
                lastX: x,
                lastY: y,
                awaitingAxisInitialization: x == 0 || y == 0
            ),
            for: slot
        )
    }

    private mutating func updateContact(slot: ContactSlot, x: Double, y: Double) {
        guard var contact = contact(for: slot) else { return }

        let xSnappedToZero = contact.lastX != 0 && x == 0 && y == contact.lastY
        let ySnappedToZero = contact.lastY != 0 && y == 0 && x == contact.lastX
        if xSnappedToZero || ySnappedToZero {
            // The two axes reset in separate callbacks on lift. Defer this
            // first reset so it is not counted as travel. If another real
            // coordinate follows, movement resumes from the last valid point.
            contact.hasPendingAxisReset = true
            setContact(contact, for: slot)
            return
        }

        if contact.awaitingAxisInitialization {
            let initializedX = contact.lastX == 0 && x != 0 && y == contact.lastY
            let initializedY = contact.lastY == 0 && y != 0 && x == contact.lastX
            if initializedX || initializedY {
                contact.lastX = x
                contact.lastY = y
                contact.awaitingAxisInitialization = false
                contact.hasPendingAxisReset = false
                setContact(contact, for: slot)
                return
            }
            contact.awaitingAxisInitialization = false
        }

        let deltaX = x - contact.lastX
        let deltaY = y - contact.lastY
        let step = hypot(deltaX, deltaY)
        contact.totalTravel += step
        contact.lastX = x
        contact.lastY = y
        contact.hasPendingAxisReset = false
        setContact(contact, for: slot)

        if abs(deltaX) > configuration.maximumNormalizedJump
            || abs(deltaY) > configuration.maximumNormalizedJump
            || contact.totalTravel > configuration.maximumNormalizedTravel {
            session?.isCancelled = true
        }
    }

    private mutating func finishContact(
        slot: ContactSlot,
        at timestamp: TimeInterval
    ) -> TapCandidate? {
        guard contact(for: slot) != nil else { return nil }
        setContact(nil, for: slot)

        guard primaryContact == nil,
              secondaryContact == nil,
              let completedSession = session else {
            return nil
        }

        session = nil
        lastSessionEndedAt = timestamp

        let duration = timestamp - completedSession.startedAt
        let isTap = completedSession.sawPrimary
            && !completedSession.isCancelled
            && duration >= 0
            && duration <= configuration.maximumDuration
        lastSessionWasCancelled = !isTap

        guard isTap else {
            pendingTap = nil
            return nil
        }

        nextTapID &+= 1
        let candidate = TapCandidate(
            id: nextTapID,
            button: completedSession.sawSecondary ? .right : .left,
            delay: configuration.releaseDebounce
        )
        pendingTap = candidate
        return candidate
    }

    private func contact(for slot: ContactSlot) -> Contact? {
        switch slot {
        case .primary: primaryContact
        case .secondary: secondaryContact
        }
    }

    private mutating func setContact(_ contact: Contact?, for slot: ContactSlot) {
        switch slot {
        case .primary: primaryContact = contact
        case .secondary: secondaryContact = contact
        }
    }
}

public struct CursorDestination: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Accumulates high-frequency pointer deltas without waiting for macOS to
/// update its asynchronously posted cursor position between events.
public struct CursorIntegrator: Sendable {
    public var resynchronizationInterval: TimeInterval

    private var integratedPosition: CursorDestination?
    private var lastTimestamp: TimeInterval?

    public init(resynchronizationInterval: TimeInterval = 0.12) {
        self.resynchronizationInterval = resynchronizationInterval
    }

    public mutating func destination(
        actualX: Double,
        actualY: Double,
        deltaX: Double,
        deltaY: Double,
        at timestamp: TimeInterval
    ) -> CursorDestination {
        let base: CursorDestination
        if let integratedPosition,
           let lastTimestamp,
           timestamp >= lastTimestamp,
           timestamp - lastTimestamp <= resynchronizationInterval {
            base = integratedPosition
        } else {
            base = CursorDestination(x: actualX, y: actualY)
        }

        let next = CursorDestination(
            x: base.x + deltaX,
            y: base.y + deltaY
        )
        integratedPosition = next
        lastTimestamp = timestamp
        return next
    }

    public mutating func reset() {
        integratedPosition = nil
        lastTimestamp = nil
    }

    /// Keeps the accumulator aligned when the operating system constrains a
    /// posted cursor position (for example, at the edge of a display).
    public mutating func synchronize(
        x: Double,
        y: Double,
        at timestamp: TimeInterval
    ) {
        integratedPosition = CursorDestination(x: x, y: y)
        lastTimestamp = timestamp
    }
}

public struct GestureEngine: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var contactTimeout: TimeInterval
        public var secondaryContactTimeout: TimeInterval
        public var maximumNormalizedJump: Double
        public var rightClickThreshold: Double

        public init(
            contactTimeout: TimeInterval = 0.18,
            secondaryContactTimeout: TimeInterval = 0.14,
            maximumNormalizedJump: Double = 0.22,
            rightClickThreshold: Double = 0.25
        ) {
            self.contactTimeout = contactTimeout
            self.secondaryContactTimeout = secondaryContactTimeout
            self.maximumNormalizedJump = maximumNormalizedJump
            self.rightClickThreshold = rightClickThreshold
        }
    }

    private struct Sample: Sendable {
        let x: Double
        let y: Double
        let timestamp: TimeInterval
    }

    public var configuration: Configuration

    private var primarySample: Sample?
    private var secondarySample: Sample?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func primaryChanged(
        x: Double,
        y: Double,
        at timestamp: TimeInterval
    ) -> GestureAction? {
        let next = Sample(x: x, y: y, timestamp: timestamp)
        defer { primarySample = next }

        guard !hasRecentSecondaryContact(at: timestamp) else {
            return nil
        }

        guard let previous = primarySample,
              isContinuous(previous: previous, next: next) else {
            return nil
        }

        return .move(
            deltaX: next.x - previous.x,
            deltaY: next.y - previous.y
        )
    }

    public mutating func secondaryChanged(
        x: Double,
        y: Double,
        at timestamp: TimeInterval
    ) -> GestureAction? {
        let next = Sample(x: x, y: y, timestamp: timestamp)
        defer { secondarySample = next }

        guard let previous = secondarySample,
              isContinuous(previous: previous, next: next) else {
            return nil
        }

        return .scroll(
            deltaX: next.x - previous.x,
            deltaY: next.y - previous.y
        )
    }

    public func mouseButton(
        at timestamp: TimeInterval,
        rightSideClickEnabled: Bool
    ) -> BridgeMouseButton {
        if hasRecentSecondaryContact(at: timestamp) {
            return .right
        }

        if rightSideClickEnabled,
           let primarySample,
           timestamp >= primarySample.timestamp,
           timestamp - primarySample.timestamp <= configuration.contactTimeout,
           primarySample.x >= configuration.rightClickThreshold {
            return .right
        }

        return .left
    }

    public mutating func reset() {
        primarySample = nil
        secondarySample = nil
    }

    private func hasRecentSecondaryContact(at timestamp: TimeInterval) -> Bool {
        guard let secondarySample else { return false }
        let age = timestamp - secondarySample.timestamp
        return age >= 0 && age <= configuration.secondaryContactTimeout
    }

    private func isContinuous(previous: Sample, next: Sample) -> Bool {
        let elapsed = next.timestamp - previous.timestamp
        guard elapsed >= 0 && elapsed <= configuration.contactTimeout else {
            return false
        }

        // GameController reports the DualSense touchpad's two axes in
        // separate callbacks. On contact and release, an axis briefly uses an
        // exact zero as its inactive value. Treat that transition as a new
        // baseline, not pointer movement. Real touch coordinates are derived
        // from integer sensor positions and do not land on exact zero.
        let xChanged = next.x != previous.x
        let yChanged = next.y != previous.y
        let xCrossesInactiveValue = xChanged && (next.x == 0 || previous.x == 0)
        let yCrossesInactiveValue = yChanged && (next.y == 0 || previous.y == 0)
        guard !xCrossesInactiveValue && !yCrossesInactiveValue else {
            return false
        }

        return abs(next.x - previous.x) <= configuration.maximumNormalizedJump
            && abs(next.y - previous.y) <= configuration.maximumNormalizedJump
    }
}
