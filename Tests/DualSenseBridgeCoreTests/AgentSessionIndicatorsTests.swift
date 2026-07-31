import Foundation
import Testing
@testable import DualSenseBridgeCore

@Test func displayNamesAreShortAndRecognizable() {
    let claude = AgentSessionIndicators.displayName(
        transcriptPath: "/Users/example/.claude/projects/-Users-example-project/11111111-1111-4111-8111-111111111111.jsonl",
        source: "claude-code"
    )
    #expect(claude == "project · 11111111")

    let codex = AgentSessionIndicators.displayName(
        transcriptPath: "/Users/example/.codex/sessions/2026/07/24/rollout-2026-07-24T14-58-36-22222222-2222-4222-8222-222222222222.jsonl",
        source: "codex"
    )
    #expect(codex == "codex · 14:58")

    let unknown = AgentSessionIndicators.displayName(
        transcriptPath: "/tmp/something-else.jsonl",
        source: "other"
    )
    #expect(unknown == "something-else")
}

@Test func playerLEDReportsTouchOnlyTheIndicatorField() {
    let bluetooth = DualSenseBluetoothAudioPacketBuilder.playerLEDReport(
        mask: 0b10101,
        sequence: 2
    )
    #expect(bluetooth.count == DualSenseBluetoothAudioPacketBuilder.controlReportLength)
    #expect(bluetooth[0] == 0x31)
    #expect(bluetooth[1] == 2 << 4)
    #expect(bluetooth[2] == 0x10)
    #expect(bluetooth[4] == 0x10) // AllowPlayerIndicators only
    #expect(bluetooth[46] == 0b10101)
    // Nothing else in the SetState block may be marked valid or nonzero:
    // audio routing, mute, lightbar, and motors all stay untouched.
    #expect(bluetooth[3] == 0x00)
    for index in 5..<74 where index != 46 {
        #expect(bluetooth[index] == 0x00)
    }
    let crc = DualSenseBluetoothAudioPacketBuilder.crc32Sony(bluetooth[..<74])
    #expect(bluetooth[74] == UInt8(truncatingIfNeeded: crc))

    let usb = DualSenseBluetoothAudioPacketBuilder.usbPlayerLEDReport(mask: 0b00110)
    #expect(usb.count == DualSenseBluetoothAudioPacketBuilder.usbOutputReportLength)
    #expect(usb[0] == 0x02)
    #expect(usb[2] == 0x10)
    #expect(usb[44] == 0b00110)
    #expect(usb[1] == 0x00)
    for index in 3..<usb.count where index != 44 {
        #expect(usb[index] == 0x00)
    }
}

@Test func playerLEDMasksAreCappedToFiveBits() {
    #expect(DualSenseBluetoothAudioPacketBuilder.playerLEDReport(mask: 0xff)[46] == 0x1f)
    #expect(DualSenseBluetoothAudioPacketBuilder.usbPlayerLEDReport(mask: 0xff)[44] == 0x1f)
}

@Test func playerLEDReportsCanRequestAnImmediateChange() {
    #expect(
        DualSenseBluetoothAudioPacketBuilder.playerLEDReport(
            mask: 0b00100,
            immediate: true
        )[46] == 0b100100
    )
    #expect(
        DualSenseBluetoothAudioPacketBuilder.usbPlayerLEDReport(
            mask: 0b10000,
            immediate: true
        )[44] == 0b110000
    )
}

@Test func focusPatternsUseSonySymmetryAndCountFromOneThroughFive() {
    #expect(AgentSessionIndicators.focusMask(forPosition: 0) == 0b00100)
    #expect(AgentSessionIndicators.focusMask(forPosition: 1) == 0b01010)
    #expect(AgentSessionIndicators.focusMask(forPosition: 2) == 0b10101)
    #expect(AgentSessionIndicators.focusMask(forPosition: 3) == 0b11011)
    #expect(AgentSessionIndicators.focusMask(forPosition: 4) == 0b11111)
    #expect(AgentSessionIndicators.focusMask(forPosition: -1) == nil)
    #expect(AgentSessionIndicators.focusMask(forPosition: 5) == nil)

    #expect(AgentSessionIndicators.focusDiagram(forPosition: 0) == "○○●○○")
    #expect(AgentSessionIndicators.focusDiagram(forPosition: 1) == "○●○●○")
    #expect(AgentSessionIndicators.focusDiagram(forPosition: 2) == "●○●○●")
    #expect(AgentSessionIndicators.focusDiagram(forPosition: 3) == "●●○●●")
    #expect(AgentSessionIndicators.focusDiagram(forPosition: 4) == "●●●●●")
}

@Test func focusPagesRestartTheOneThroughFiveCount() {
    #expect(AgentSessionIndicators.cursorSlot(forSessionOrdinal: 0) == 0)
    #expect(AgentSessionIndicators.cursorPage(forSessionOrdinal: 0) == 1)
    #expect(AgentSessionIndicators.cursorSlot(forSessionOrdinal: 4) == 4)
    #expect(AgentSessionIndicators.cursorPage(forSessionOrdinal: 4) == 1)
    #expect(AgentSessionIndicators.cursorSlot(forSessionOrdinal: 5) == 0)
    #expect(AgentSessionIndicators.cursorPage(forSessionOrdinal: 5) == 2)
    #expect(AgentSessionIndicators.cursorSlot(forSessionOrdinal: 11) == 1)
    #expect(AgentSessionIndicators.cursorPage(forSessionOrdinal: 11) == 3)
    #expect(AgentSessionIndicators.cursorSlot(forSessionOrdinal: -1) == nil)
    #expect(AgentSessionIndicators.cursorPage(forSessionOrdinal: -1) == nil)
}
