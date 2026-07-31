import Testing
@testable import DualSenseBridgeCore

@Test func heldTwoFingerSwipeLeftMovesToTheRightSpaceOnce() {
    var recognizer = TouchpadWorkspaceSwipeRecognizer()
    #expect(recognizer.primaryChanged(
        x: -0.35,
        y: -0.05,
        isActive: true,
        at: 1.00
    ) == nil)
    #expect(recognizer.secondaryChanged(
        x: 0.15,
        y: 0.05,
        isActive: true,
        at: 1.01
    ) == nil)
    #expect(recognizer.touchpadButtonChanged(pressed: true, at: 1.02) == .began)

    #expect(recognizer.primaryChanged(
        x: -0.65,
        y: -0.04,
        isActive: true,
        at: 1.05
    ) == nil)
    let direction = recognizer.secondaryChanged(
        x: -0.15,
        y: 0.06,
        isActive: true,
        at: 1.06
    )
    #expect(direction == .left)
    #expect(direction?.macOSSpaceShortcut == .controlRightArrow)

    #expect(recognizer.primaryChanged(
        x: -0.75,
        y: -0.04,
        isActive: true,
        at: 1.07
    ) == nil)
    #expect(recognizer.touchpadButtonChanged(
        pressed: false,
        at: 1.10
    ) == .endedAfterSwipe)
}

@Test func heldTwoFingerSwipeRightMovesToTheLeftSpace() {
    var recognizer = TouchpadWorkspaceSwipeRecognizer()
    _ = recognizer.primaryChanged(x: -0.25, y: 0.0, isActive: true, at: 1.00)
    _ = recognizer.secondaryChanged(x: 0.25, y: 0.1, isActive: true, at: 1.01)
    #expect(recognizer.touchpadButtonChanged(pressed: true, at: 1.02) == .began)

    #expect(recognizer.primaryChanged(
        x: 0.03,
        y: 0.01,
        isActive: true,
        at: 1.05
    ) == nil)
    let direction = recognizer.secondaryChanged(
        x: 0.53,
        y: 0.11,
        isActive: true,
        at: 1.06
    )
    #expect(direction == .right)
    #expect(direction?.macOSSpaceShortcut == .controlLeftArrow)
}

@Test func heldTwoFingerPressWithoutTravelRemainsRightClick() {
    var recognizer = TouchpadWorkspaceSwipeRecognizer()
    _ = recognizer.primaryChanged(x: -0.2, y: 0.1, isActive: true, at: 1.00)
    _ = recognizer.secondaryChanged(x: 0.2, y: 0.1, isActive: true, at: 1.01)
    #expect(recognizer.touchpadButtonChanged(pressed: true, at: 1.02) == .began)

    _ = recognizer.primaryChanged(x: -0.18, y: 0.11, isActive: true, at: 1.03)
    _ = recognizer.secondaryChanged(x: 0.22, y: 0.09, isActive: true, at: 1.04)
    #expect(recognizer.touchpadButtonChanged(
        pressed: false,
        at: 1.08
    ) == .endedAsRightClick)
}

@Test func verticalHeldMovementCancelsWithoutRightClick() {
    var recognizer = TouchpadWorkspaceSwipeRecognizer()
    _ = recognizer.primaryChanged(x: -0.2, y: -0.2, isActive: true, at: 1.00)
    _ = recognizer.secondaryChanged(x: 0.2, y: -0.1, isActive: true, at: 1.01)
    #expect(recognizer.touchpadButtonChanged(pressed: true, at: 1.02) == .began)

    _ = recognizer.primaryChanged(x: -0.19, y: 0.15, isActive: true, at: 1.05)
    #expect(recognizer.secondaryChanged(
        x: 0.21,
        y: 0.25,
        isActive: true,
        at: 1.06
    ) == nil)
    #expect(recognizer.touchpadButtonChanged(
        pressed: false,
        at: 1.08
    ) == .endedCancelled)
}

@Test func pinchDoesNotBecomeWorkspaceSwipeOrRightClick() {
    var recognizer = TouchpadWorkspaceSwipeRecognizer()
    _ = recognizer.primaryChanged(x: -0.1, y: 0.0, isActive: true, at: 1.00)
    _ = recognizer.secondaryChanged(x: 0.1, y: 0.0, isActive: true, at: 1.01)
    #expect(recognizer.touchpadButtonChanged(pressed: true, at: 1.02) == .began)

    _ = recognizer.primaryChanged(x: -0.35, y: 0.0, isActive: true, at: 1.05)
    #expect(recognizer.secondaryChanged(
        x: 0.35,
        y: 0.0,
        isActive: true,
        at: 1.06
    ) == nil)
    #expect(recognizer.touchpadButtonChanged(
        pressed: false,
        at: 1.08
    ) == .endedCancelled)
}

@Test func workspaceSwipeRequiresTwoFreshContactsBeforePress() {
    var recognizer = TouchpadWorkspaceSwipeRecognizer()
    _ = recognizer.primaryChanged(x: -0.2, y: 0.0, isActive: true, at: 1.00)
    #expect(recognizer.touchpadButtonChanged(pressed: true, at: 1.02) == .ignored)

    recognizer.reset()
    _ = recognizer.primaryChanged(x: -0.2, y: 0.0, isActive: true, at: 2.00)
    _ = recognizer.secondaryChanged(x: 0.2, y: 0.0, isActive: true, at: 2.01)
    #expect(recognizer.touchpadButtonChanged(pressed: true, at: 2.50) == .ignored)
}
