import Testing
@testable import DualSenseBridgeCore

@Test func firstPrimarySampleEstablishesBaseline() {
    var engine = GestureEngine()
    #expect(engine.primaryChanged(x: -0.4, y: 0.2, at: 1.0) == nil)
    guard case let .move(deltaX, deltaY)? = engine.primaryChanged(x: -0.3, y: 0.4, at: 1.01) else {
        Issue.record("Expected a pointer movement")
        return
    }
    #expect(abs(deltaX - 0.1) < 0.000_001)
    #expect(abs(deltaY - 0.2) < 0.000_001)
}

@Test func aNewContactDoesNotJumpThePointer() {
    var engine = GestureEngine()
    _ = engine.primaryChanged(x: -0.8, y: 0.0, at: 1.0)
    _ = engine.primaryChanged(x: -0.7, y: 0.0, at: 1.01)

    #expect(engine.primaryChanged(x: 0.8, y: 0.0, at: 1.5) == nil)
    guard case let .move(deltaX, deltaY)? = engine.primaryChanged(x: 0.7, y: 0.0, at: 1.51) else {
        Issue.record("Expected movement after the new baseline")
        return
    }
    #expect(abs(deltaX + 0.1) < 0.000_001)
    #expect(abs(deltaY) < 0.000_001)
}

@Test func implausiblyLargeJumpIsFiltered() {
    var engine = GestureEngine()
    _ = engine.primaryChanged(x: -0.9, y: -0.9, at: 1.0)
    #expect(engine.primaryChanged(x: 0.9, y: 0.9, at: 1.01) == nil)
}

@Test func contactAxisInitializationIsNotPointerMovement() {
    var engine = GestureEngine()
    _ = engine.primaryChanged(x: 0.13, y: 0, at: 1.0)

    // The axes arrive separately when a finger first touches the pad.
    #expect(engine.primaryChanged(x: 0.13, y: 0.49, at: 1.001) == nil)

    guard case let .move(deltaX, deltaY)? = engine.primaryChanged(
        x: 0.14,
        y: 0.50,
        at: 1.01
    ) else {
        Issue.record("Expected movement after both axes established a baseline")
        return
    }
    #expect(abs(deltaX - 0.01) < 0.000_001)
    #expect(abs(deltaY - 0.01) < 0.000_001)
}

@Test func touchReleaseToNeutralDoesNotMovePointer() {
    var engine = GestureEngine()
    _ = engine.primaryChanged(x: 0.05, y: -0.08, at: 1.0)

    // Even a small release jump must be suppressed; size alone cannot
    // distinguish it from intentional movement near the pad's centre.
    #expect(engine.primaryChanged(x: 0, y: -0.08, at: 1.001) == nil)
    #expect(engine.primaryChanged(x: 0, y: 0, at: 1.002) == nil)
}

@Test func oneFingerTapProducesLeftClick() {
    var recognizer = TouchpadTapRecognizer()
    #expect(recognizer.primaryChanged(x: 0.25, y: 0, at: 1.0) == nil)
    #expect(recognizer.primaryChanged(x: 0.25, y: 0.4, at: 1.001) == nil)

    // The axes reset separately when the finger lifts.
    #expect(recognizer.primaryChanged(x: 0, y: 0.4, at: 1.10) == nil)
    guard let candidate = recognizer.primaryChanged(x: 0, y: 0, at: 1.101) else {
        Issue.record("Expected a one-finger tap")
        return
    }

    #expect(candidate.button == .left)
    #expect(recognizer.consumePendingTap(id: candidate.id) == .left)
    #expect(recognizer.consumePendingTap(id: candidate.id) == nil)
}

@Test func twoFingerTapProducesRightClick() {
    var recognizer = TouchpadTapRecognizer()
    _ = recognizer.primaryChanged(x: -0.2, y: 0, at: 1.0)
    _ = recognizer.primaryChanged(x: -0.2, y: 0.3, at: 1.001)
    _ = recognizer.secondaryChanged(x: 0.2, y: 0, at: 1.01)
    _ = recognizer.secondaryChanged(x: 0.2, y: 0.3, at: 1.011)

    _ = recognizer.secondaryChanged(x: 0, y: 0.3, at: 1.10)
    #expect(recognizer.secondaryChanged(x: 0, y: 0, at: 1.101) == nil)
    _ = recognizer.primaryChanged(x: 0, y: 0.3, at: 1.11)
    guard let candidate = recognizer.primaryChanged(x: 0, y: 0, at: 1.111) else {
        Issue.record("Expected a two-finger tap")
        return
    }

    #expect(candidate.button == .right)
    #expect(recognizer.consumePendingTap(id: candidate.id) == .right)
}

@Test func movingFingerDoesNotBecomeTapOnLift() {
    var recognizer = TouchpadTapRecognizer()
    _ = recognizer.primaryChanged(x: 0.2, y: 0.2, at: 1.0)
    _ = recognizer.primaryChanged(x: 0.3, y: 0.2, at: 1.02)
    #expect(recognizer.primaryChanged(x: 0, y: 0, at: 1.10) == nil)
}

@Test func physicalTouchpadClickSuppressesTapClick() {
    var recognizer = TouchpadTapRecognizer()
    _ = recognizer.primaryChanged(x: 0.2, y: 0.2, at: 1.0)
    recognizer.touchpadButtonChanged(pressed: true)
    recognizer.touchpadButtonChanged(pressed: false)
    #expect(recognizer.primaryChanged(x: 0, y: 0, at: 1.10) == nil)
}

@Test func rapidNeutralCoordinateDoesNotFirePrematureTap() {
    var recognizer = TouchpadTapRecognizer()
    _ = recognizer.primaryChanged(x: 0.02, y: 0.02, at: 1.0)
    guard let prematureCandidate = recognizer.primaryChanged(x: 0, y: 0, at: 1.05) else {
        Issue.record("Expected a debounced tap candidate")
        return
    }

    // A new coordinate inside the debounce window means the finger crossed
    // the pad's exact centre and never actually lifted.
    _ = recognizer.primaryChanged(x: -0.02, y: 0.02, at: 1.055)
    #expect(recognizer.consumePendingTap(id: prematureCandidate.id) == nil)

    guard let finalCandidate = recognizer.primaryChanged(x: 0, y: 0, at: 1.10) else {
        Issue.record("Expected a tap at the real lift")
        return
    }
    #expect(recognizer.consumePendingTap(id: finalCandidate.id) == .left)
}

@Test func swipeThroughNeutralCannotCreateTapFromItsTail() {
    var recognizer = TouchpadTapRecognizer()
    _ = recognizer.primaryChanged(x: 0.4, y: 0.4, at: 1.0)
    _ = recognizer.primaryChanged(x: 0.6, y: 0.4, at: 1.02)
    #expect(recognizer.primaryChanged(x: 0, y: 0, at: 1.04) == nil)

    // This is a continuation immediately after crossing neutral, not a new
    // tap, even if the remaining segment is short.
    _ = recognizer.primaryChanged(x: -0.02, y: 0.02, at: 1.045)
    #expect(recognizer.primaryChanged(x: 0, y: 0, at: 1.08) == nil)
}

@Test func moderateCoordinateResetIsFiltered() {
    var engine = GestureEngine()
    _ = engine.primaryChanged(x: 0.2, y: 0.5, at: 1.0)

    // This is representative of the 0.42–0.49 release transitions observed
    // from the live DualSense trace and was accepted by the old 0.80 limit.
    #expect(engine.primaryChanged(x: 0.2, y: 0.08, at: 1.001) == nil)
}

@Test func secondaryFingerScrollsAndSuppressesPointer() {
    var engine = GestureEngine()
    _ = engine.primaryChanged(x: 0.0, y: 0.0, at: 1.0)
    #expect(engine.secondaryChanged(x: 0.1, y: 0.1, at: 1.01) == nil)
    #expect(engine.primaryChanged(x: 0.1, y: 0.1, at: 1.02) == nil)
    guard case let .scroll(deltaX, deltaY)? = engine.secondaryChanged(x: 0.2, y: 0.3, at: 1.03) else {
        Issue.record("Expected a two-finger scroll")
        return
    }
    #expect(abs(deltaX - 0.1) < 0.000_001)
    #expect(abs(deltaY - 0.2) < 0.000_001)
}

@Test func twoFingerOrRightSidePressProducesRightClick() {
    var engine = GestureEngine()
    _ = engine.primaryChanged(x: 0.7, y: 0.0, at: 1.0)
    #expect(engine.mouseButton(at: 1.01, rightSideClickEnabled: true) == .right)

    engine.reset()
    _ = engine.primaryChanged(x: -0.7, y: 0.0, at: 2.0)
    _ = engine.secondaryChanged(x: 0.0, y: 0.0, at: 2.01)
    #expect(engine.mouseButton(at: 2.02, rightSideClickEnabled: false) == .right)
}

@Test func leftSidePressDefaultsToLeftClick() {
    var engine = GestureEngine()
    _ = engine.primaryChanged(x: -0.5, y: 0.0, at: 1.0)
    #expect(engine.mouseButton(at: 1.01, rightSideClickEnabled: true) == .left)
}

@Test func staleRightSideTouchCannotChangeALaterPressToRightClick() {
    var engine = GestureEngine()
    _ = engine.primaryChanged(x: 0.8, y: 0.0, at: 1.0)

    #expect(engine.mouseButton(at: 1.5, rightSideClickEnabled: true) == .left)
}

@Test func rapidCursorDeltasAccumulateBeforeMacOSCatchesUp() {
    var integrator = CursorIntegrator()

    let first = integrator.destination(
        actualX: 100,
        actualY: 200,
        deltaX: 5,
        deltaY: 0,
        at: 1.0
    )
    #expect(first == CursorDestination(x: 105, y: 200))

    // The OS still reports x=100, but the second delta must build on the
    // already-posted x=105 rather than losing the first movement.
    let second = integrator.destination(
        actualX: 100,
        actualY: 200,
        deltaX: 5,
        deltaY: 0,
        at: 1.01
    )
    #expect(second == CursorDestination(x: 110, y: 200))
}

@Test func cursorIntegratorResynchronizesAfterInputPauses() {
    var integrator = CursorIntegrator(resynchronizationInterval: 0.1)
    _ = integrator.destination(actualX: 100, actualY: 200, deltaX: 5, deltaY: 0, at: 1.0)

    let destination = integrator.destination(
        actualX: 400,
        actualY: 300,
        deltaX: -10,
        deltaY: 2,
        at: 1.5
    )
    #expect(destination == CursorDestination(x: 390, y: 302))
}

@Test func cursorIntegratorCanSynchronizeAfterDisplayClamping() {
    var integrator = CursorIntegrator()
    _ = integrator.destination(
        actualX: 100,
        actualY: 100,
        deltaX: -150,
        deltaY: 0,
        at: 1.0
    )

    // WindowServer clamps the posted position to the left edge.
    integrator.synchronize(x: 0, y: 100, at: 1.0)
    let destination = integrator.destination(
        actualX: 0,
        actualY: 100,
        deltaX: 5,
        deltaY: 0,
        at: 1.01
    )
    #expect(destination == CursorDestination(x: 5, y: 100))
}

@Test func keyboardShortcutDisplaysModifiersInMacOrder() {
    let shortcut = KeyboardShortcut(
        keyCode: 8,
        modifiers: [.command, .option, .control, .shift],
        keyLabel: "C"
    )

    #expect(shortcut.displayText == "⌃⌥⇧⌘C")
}

@Test func circleDefaultsToReturnShortcut() {
    #expect(KeyboardShortcut.returnKey.keyCode == 36)
    #expect(KeyboardShortcut.returnKey.modifiers.isEmpty)
    #expect(KeyboardShortcut.returnKey.displayText == "Return")
}

@Test func codexDictationShortcutIsCommandO() {
    #expect(KeyboardShortcut.commandO.keyCode == 31)
    #expect(KeyboardShortcut.commandO.modifiers == .command)
    #expect(KeyboardShortcut.commandO.displayText == "⌘O")
}

@Test func commandOEmitsCompletePressAndReleaseChord() {
    #expect(KeyboardShortcut.commandO.chordEvents(pressed: true) == [
        KeyboardChordEvent(keyCode: 55, modifiers: .command, keyDown: true, isModifier: true),
        KeyboardChordEvent(keyCode: 31, modifiers: .command, keyDown: true)
    ])
    #expect(KeyboardShortcut.commandO.chordEvents(pressed: false) == [
        KeyboardChordEvent(keyCode: 31, modifiers: .command, keyDown: false),
        KeyboardChordEvent(keyCode: 55, modifiers: [], keyDown: false, isModifier: true)
    ])
}

@Test func multiModifierChordReleasesModifiersInReverseOrder() {
    let shortcut = KeyboardShortcut(
        keyCode: 35,
        modifiers: [.control, .shift, .command],
        keyLabel: "P"
    )

    #expect(shortcut.chordEvents(pressed: true) == [
        KeyboardChordEvent(keyCode: 59, modifiers: .control, keyDown: true, isModifier: true),
        KeyboardChordEvent(keyCode: 56, modifiers: [.control, .shift], keyDown: true, isModifier: true),
        KeyboardChordEvent(keyCode: 55, modifiers: [.control, .shift, .command], keyDown: true, isModifier: true),
        KeyboardChordEvent(keyCode: 35, modifiers: [.control, .shift, .command], keyDown: true)
    ])
    #expect(shortcut.chordEvents(pressed: false) == [
        KeyboardChordEvent(keyCode: 35, modifiers: [.control, .shift, .command], keyDown: false),
        KeyboardChordEvent(keyCode: 55, modifiers: [.control, .shift], keyDown: false, isModifier: true),
        KeyboardChordEvent(keyCode: 56, modifiers: .control, keyDown: false, isModifier: true),
        KeyboardChordEvent(keyCode: 59, modifiers: [], keyDown: false, isModifier: true)
    ])
}

@Test func shortcutButtonsHaveStableStorageNames() {
    #expect(ControllerShortcutButton.allCases.map(\.storageName) == [
        "triangle",
        "square",
        "cross",
        "circle",
        "l1",
        "l2",
        "r1",
        "r2",
        "dpadUp",
        "dpadRight",
        "dpadDown",
        "dpadLeft",
        "l3",
        "r3",
        "create",
        "options",
        "playStation",
        "touchpadClick",
        "mute",
        "leftStickUp",
        "leftStickRight",
        "leftStickDown",
        "leftStickLeft",
        "rightStickUp",
        "rightStickRight",
        "rightStickDown",
        "rightStickLeft"
    ])
}

@Test func onlyVirtualStickDirectionsRepeatWhileHeld() {
    let repeatingButtons = Set(
        ControllerShortcutButton.allCases
            .filter(\.repeatsWhileHeld)
    )

    #expect(repeatingButtons == Set([
        .leftStickUp,
        .leftStickRight,
        .leftStickDown,
        .leftStickLeft,
        .rightStickUp,
        .rightStickRight,
        .rightStickDown,
        .rightStickLeft
    ]))
}

@Test func analogTriggerLatchUsesHysteresisAndOnlyEmitsEdges() {
    var latch = AnalogTriggerLatch(pressThreshold: 128, releaseThreshold: 96)

    #expect(latch.update(value: 40) == nil)
    #expect(latch.update(value: 127) == nil)
    #expect(latch.update(value: 128) == true)
    #expect(latch.isPressed)
    #expect(latch.update(value: 110) == nil)
    #expect(latch.update(value: 97) == nil)
    #expect(latch.update(value: 96) == false)
    #expect(!latch.isPressed)
    #expect(latch.update(value: 0) == nil)
}

@Test func analogTriggerLatchCanBeResetWhilePressed() {
    var latch = AnalogTriggerLatch()
    #expect(latch.update(value: 255) == true)

    latch.reset()

    #expect(!latch.isPressed)
    #expect(latch.update(value: 255) == true)
}

@Test func analogAxisDirectionLatchUsesHysteresisAroundCenter() {
    var latch = AnalogAxisDirectionLatch(
        pressDistance: 64,
        releaseDistance: 40
    )

    #expect(latch.update(value: 128) == AnalogAxisDirectionUpdate(
        negativePressed: nil,
        positivePressed: nil
    ))
    #expect(latch.update(value: 65).negativePressed == nil)
    #expect(latch.update(value: 64).negativePressed == true)
    #expect(latch.isNegativePressed)
    #expect(latch.update(value: 80).negativePressed == nil)
    #expect(latch.update(value: 88).negativePressed == false)
    #expect(!latch.isNegativePressed)

    #expect(latch.update(value: 191).positivePressed == nil)
    #expect(latch.update(value: 192).positivePressed == true)
    #expect(latch.update(value: 168).positivePressed == false)
    #expect(!latch.isPositivePressed)
}

@Test func analogAxisDirectionLatchCanSwitchSidesAndReset() {
    var latch = AnalogAxisDirectionLatch()
    #expect(latch.update(value: 0).negativePressed == true)

    let crossing = latch.update(value: 255)
    #expect(crossing.negativePressed == false)
    #expect(crossing.positivePressed == true)

    latch.reset()
    #expect(!latch.isNegativePressed)
    #expect(!latch.isPositivePressed)
}
