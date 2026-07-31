import Testing
@testable import DualSenseBridgeCore

@Test func standardButtonProfileMatchesTheMaintainerLayout() {
    let profile = ControllerButtonMappingProfile.standard

    #expect(profile.shortcuts.count == 11)
    #expect(profile.shortcuts[.triangle] == .commandO)
    #expect(profile.shortcuts[.square]?.displayText == "Escape")
    #expect(profile.shortcuts[.circle] == .returnKey)
    #expect(profile.shortcuts[.l1]?.displayText == "⌘[")
    #expect(profile.shortcuts[.l2]?.displayText == "⇧⌘{")
    #expect(profile.shortcuts[.r1]?.displayText == "⌘]")
    #expect(profile.shortcuts[.r2]?.displayText == "⇧⌘}")
    #expect(profile.shortcuts[.leftStickUp]?.displayText == "fn ↑")
    #expect(profile.shortcuts[.leftStickRight]?.displayText == "fn →")
    #expect(profile.shortcuts[.leftStickDown]?.displayText == "fn ↓")
    #expect(profile.shortcuts[.leftStickLeft]?.displayText == "fn ←")
    #expect(profile.microphoneButtons == [.triangle])
    #expect(profile.fleetButtons[.focusPrevious] == .dpadLeft)
    #expect(profile.fleetButtons[.focusNext] == .dpadRight)
    #expect(profile.fleetButtons[.raiseFocused] == .dpadUp)
}

@Test func standardButtonProfileHasNoConflictingEffectiveAssignments() {
    let profile = ControllerButtonMappingProfile.standard
    let fleetButtons = Array(profile.fleetButtons.values)

    #expect(Set(fleetButtons).count == FleetAction.allCases.count)
    #expect(Set(profile.shortcuts.keys).isDisjoint(with: fleetButtons))
    #expect(profile.microphoneButtons.isSubset(of: Set(profile.shortcuts.keys)))
}
