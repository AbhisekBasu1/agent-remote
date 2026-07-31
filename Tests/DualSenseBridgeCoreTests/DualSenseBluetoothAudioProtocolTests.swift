import Foundation
import Testing
@testable import DualSenseBridgeCore

struct DualSenseBluetoothAudioProtocolTests {
    @Test func setupReportHasExpectedSonyCRC() {
        let report = DualSenseBluetoothAudioPacketBuilder.setupReport()

        #expect(report.count == 78)
        #expect(report[0] == 0x31)
        #expect(report[1] == 0x00)
        #expect(report[2] == 0x10)
        #expect(Array(report[74...77]) == [0x89, 0x13, 0xeb, 0x44])
    }

    @Test func microphoneStreamControlUsesCompactOneBytePayload() {
        var builder = DualSenseBluetoothAudioPacketBuilder()
        let enabled = builder.audioReport(microphoneEnabled: true)
        let cleanup = builder.audioReport(microphoneEnabled: false)

        #expect(enabled.count == 142)
        #expect(enabled[0] == 0x32)
        #expect(enabled[2] == 0x91)
        #expect(enabled[3] == 1)
        #expect(enabled[4] == 0x03)
        #expect(enabled[5..<138].allSatisfy { $0 == 0 })
        #expect(cleanup[4] == 0x02)
        #expect(enabled[1] == 0x00)
        #expect(cleanup[1] == 0x10)

        let enabledCRC = UInt32(enabled[138])
            | (UInt32(enabled[139]) << 8)
            | (UInt32(enabled[140]) << 16)
            | (UInt32(enabled[141]) << 24)
        #expect(enabledCRC == DualSenseBluetoothAudioPacketBuilder.crc32Sony(enabled[..<138]))
    }

    @Test func microphoneStateUsesMinimalSonyMuteFields() {
        let unmuted = DualSenseBluetoothAudioPacketBuilder.microphoneStateReport(
            muted: false,
            sequence: 3
        )
        let muted = DualSenseBluetoothAudioPacketBuilder.microphoneStateReport(
            muted: true,
            sequence: 4
        )

        #expect(unmuted.count == 78)
        #expect(unmuted[0] == 0x31)
        #expect(unmuted[1] == 0x30)
        #expect(unmuted[2] == 0x10)
        #expect(unmuted[3] == 0x00)
        #expect(unmuted[4] == 0x03)
        #expect(unmuted[11] == 0x00)
        #expect(unmuted[12] == 0x00)

        #expect(muted[1] == 0x40)
        #expect(muted[11] == 0x01)
        #expect(muted[12] == 0x10)

        let crc = UInt32(unmuted[74])
            | (UInt32(unmuted[75]) << 8)
            | (UInt32(unmuted[76]) << 16)
            | (UInt32(unmuted[77]) << 24)
        #expect(crc == DualSenseBluetoothAudioPacketBuilder.crc32Sony(unmuted[..<74]))
    }

    @Test func microphoneStateAndStreamReportsShareOneSequence() {
        var builder = DualSenseBluetoothAudioPacketBuilder()
        let cleanup = builder.audioReport(microphoneEnabled: false)
        let unmute = builder.microphoneStateReport(muted: false)
        let enable = builder.audioReport(microphoneEnabled: true)

        #expect(cleanup[1] == 0x00)
        #expect(unmute[1] == 0x10)
        #expect(enable[1] == 0x20)
    }

    @Test func internalMicrophoneSourceReportRestoresCompleteCapturePath() {
        let report = DualSenseBluetoothAudioPacketBuilder.internalMicrophoneSourceReport(
            sequence: 5
        )

        #expect(report.count == 78)
        #expect(report[0] == 0x31)
        #expect(report[1] == 0x50)
        #expect(report[2] == 0x10)
        #expect(report[3] == 0xc0)
        #expect(report[4] == 0x80)
        #expect(report[9] == 0x40)
        #expect(report[10] == 0x09)
        #expect(report[40] == 0x0a)

        let reduced = DualSenseBluetoothAudioPacketBuilder.internalMicrophoneSourceReport(
            microphoneVolume: 40,
            sequence: 6
        )
        #expect(reduced[9] == 40)

        let clamped = DualSenseBluetoothAudioPacketBuilder.internalMicrophoneSourceReport(
            microphoneVolume: 255,
            sequence: 7
        )
        #expect(clamped[9] == 64)
    }

    @Test func microphoneArmingReportMatchesKnownWorkingTransport() {
        var builder = DualSenseBluetoothAudioPacketBuilder()
        let report = builder.microphoneArmingReport()

        #expect(report.count == 398)
        #expect(report[0] == 0x36)
        #expect(report[1] == 0x00)
        #expect(report[2] == 0x91)
        #expect(report[3] == 7)
        #expect(report[4] == 0xff)
        #expect(Array(report[5...9]) == [64, 64, 64, 64, 64])
        #expect(report[10] == 1)
        #expect(report[11] == 0x90)
        #expect(report[12] == 63)
        #expect(report[13] == 0xfd)
        // LED ownership is deliberately excluded from the audio state.
        #expect(report[14] == 0xf3)
        #expect(report[19] == 0x40)
        #expect(report[20] == 0x09)
        #expect(report[50] == 0x0a)
        #expect(Array(report[57...59]) == [0x00, 0x00, 0x00])
        #expect(report[76] == 0x92)
        #expect(report[77] == 64)
        #expect(report[78..<394].allSatisfy { $0 == 0 })

        let crc = UInt32(report[394])
            | (UInt32(report[395]) << 8)
            | (UInt32(report[396]) << 16)
            | (UInt32(report[397]) << 24)
        #expect(crc == DualSenseBluetoothAudioPacketBuilder.crc32Sony(report[..<394]))
    }

    @Test func lightbarColorReportCannotOverwriteAudioRouting() {
        let report = DualSenseBluetoothAudioPacketBuilder.lightbarColorReport(
            red: 0x00,
            green: 0x40,
            blue: 0xff,
            sequence: 6
        )

        #expect(report.count == 78)
        #expect(report[0] == 0x31)
        #expect(report[1] == 0x60)
        #expect(report[2] == 0x10)
        #expect(report[3] == 0x00)
        #expect(report[4] == 0x04)
        #expect(report[5..<47].allSatisfy { $0 == 0 })
        #expect(Array(report[47...49]) == [0x00, 0x40, 0xff])
        #expect(report[50..<74].allSatisfy { $0 == 0 })

        let crc = UInt32(report[74])
            | (UInt32(report[75]) << 8)
            | (UInt32(report[76]) << 16)
            | (UInt32(report[77]) << 24)
        #expect(crc == DualSenseBluetoothAudioPacketBuilder.crc32Sony(report[..<74]))

        let finished = DualSenseBluetoothAudioPacketBuilder.lightbarColorReport(
            red: 0xff,
            green: 0xd7,
            blue: 0x00,
            sequence: 7
        )
        #expect(finished[3] == 0x00)
        #expect(finished[4] == 0x04)
        #expect(Array(finished[47...49]) == [0xff, 0xd7, 0x00])
    }

    /// The 0x36 arming report is sent after the 0x31 source report and its
    /// embedded SetStateData overrides the controller state. Every outbound
    /// report must therefore carry the same selected microphone volume, or a
    /// gain experiment silently reverts to the hard-coded default.
    @Test func armingReportEmbedsSelectedMicrophoneVolume() {
        var builder = DualSenseBluetoothAudioPacketBuilder()
        let quiet = builder.microphoneArmingReport(microphoneVolume: 24)
        #expect(quiet[19] == 24)

        let clamped = builder.microphoneArmingReport(microphoneVolume: 255)
        #expect(clamped[19] == 0x40)

        let crc = UInt32(quiet[394])
            | (UInt32(quiet[395]) << 8)
            | (UInt32(quiet[396]) << 16)
            | (UInt32(quiet[397]) << 24)
        #expect(crc == DualSenseBluetoothAudioPacketBuilder.crc32Sony(quiet[..<394]))
    }

    @Test func fullAudioCarrierHasTwoValidSilenceFramesAndSonyCRC() {
        var builder = DualSenseBluetoothAudioPacketBuilder()
        let report = builder.fullAudioReport(microphoneEnabled: true)

        #expect(report.count == 547)
        #expect(report[0] == 0x39)
        #expect(report[2] == 0x91)
        #expect(report[3] == 6)
        #expect(report[4] == 0x7f)
        #expect(Array(report[5...8]) == [64, 64, 64, 64])
        #expect(report[9] == 2)
        #expect(report[10] == 0xd2)
        #expect(report[11] == 64)
        #expect(report[12..<140].allSatisfy { $0 == 0 })
        #expect(report[140] == 0xd3)
        #expect(report[141] == 200)
        #expect(Array(report[142...144]) == [0xf4, 0xff, 0xfe])
        #expect(report[145..<342].allSatisfy { $0 == 0 })
        #expect(Array(report[342...344]) == [0xf4, 0xff, 0xfe])
        #expect(report[345..<543].allSatisfy { $0 == 0 })

        let crc = UInt32(report[543])
            | (UInt32(report[544]) << 8)
            | (UInt32(report[545]) << 16)
            | (UInt32(report[546]) << 24)
        #expect(crc == DualSenseBluetoothAudioPacketBuilder.crc32Sony(report[..<543]))
    }

    @Test func parserAcceptsReportsWithAndWithoutReportID() {
        var withID = [UInt8](repeating: 0, count: 78)
        withID[0] = 0x31
        withID[1] = 0x02 // microphone feedback flag
        withID[2] = 0xa7 // controller-generation counter
        withID[3] = 0xd4
        withID[4] = 0xff
        withID[5] = 0x12
        let frameWithID = withID.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.microphoneOpusFrame(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(frameWithID?.count == 71)
        #expect(frameWithID?.prefix(3) == Data([0xd4, 0xff, 0x12]))
        let packetWithID = withID.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.microphonePacket(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(packetWithID?.counter == 0xa7)
        #expect(packetWithID?.opusFrame == frameWithID)

        let withoutID = Array(withID.dropFirst())
        let frameWithoutID = withoutID.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.microphoneOpusFrame(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(frameWithoutID == frameWithID)
        let packetWithoutID = withoutID.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.microphonePacket(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(packetWithoutID == packetWithID)
    }

    /// Regression test for the encoded-silence lockout: genuine voice packets
    /// begin with the TOC byte followed by arbitrary range-coder data, not the
    /// 0xd4 0xff 0xfe silence prefix. Classification must come from the mic
    /// flag bit so speech frames are never filtered out before decoding.
    @Test func voiceFramesWithoutSilencePrefixAreAccepted() {
        var report = [UInt8](repeating: 0, count: 78)
        report[0] = 0x31
        report[1] = 0x02 // microphone feedback flag
        report[2] = 0x5a // controller audio packet counter
        report[3] = 0xd4 // Opus TOC
        report[4] = 0x2b // real speech: second byte is arbitrary
        report[5] = 0x91
        let frame = report.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.microphoneOpusFrame(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(frame?.count == 71)
        #expect(frame?.prefix(3) == Data([0xd4, 0x2b, 0x91]))

        // Without the flag bit the same bytes are a gamepad report, even if
        // stick axes coincidentally resemble an Opus header.
        report[1] = 0x00
        let notAudio = report.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.microphoneOpusFrame(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(notAudio == nil)
    }

    @Test func audioFramesAreExcludedFromFaceButtonParsing() {
        var gamepad = [UInt8](repeating: 0, count: 78)
        gamepad[0] = 0x31
        gamepad[3] = 0x80
        gamepad[10] = 0x90
        let mask = gamepad.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.faceButtonMask(reportID: 0x31, bytes: $0)
        }
        #expect(mask == 0x90)

        gamepad[1] = 0x02 // microphone feedback flag
        let audioMask = gamepad.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.faceButtonMask(reportID: 0x31, bytes: $0)
        }
        #expect(audioMask == nil)

        // A left stick held around 82 % deflection puts 0xd4 in the Y-axis
        // byte. That must never be mistaken for audio and drop button edges.
        gamepad[1] = 0x00
        gamepad[3] = 0xd4
        let stickMask = gamepad.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.faceButtonMask(reportID: 0x31, bytes: $0)
        }
        #expect(stickMask == 0x90)
    }

    @Test func fullBluetoothGamepadStateParsesButtonsAndTouchPoints() {
        var report = [UInt8](repeating: 0, count: 78)
        report[0] = 0x31
        report[2] = 32
        report[3] = 64
        report[4] = 192
        report[5] = 224
        report[6] = 180 // L2 analog value.
        report[7] = 90 // R2 analog value.
        report[9] = 0x91 // Square + Triangle + D-pad up-right.
        report[10] = 0xf3 // L1 + R1 + Create + Options + L3 + R3.
        report[11] = 0x07 // PS, touchpad, and microphone buttons.
        report[55] = 0x04 // Controller reports its microphone muted.
        report[56] = 0x01 // External microphone route is active.
        writeTouchPoint(contact: 3, x: 1_500, y: 300, at: 34, in: &report)
        writeTouchPoint(contact: 4 | 0x80, x: 900, y: 700, at: 38, in: &report)

        let withID = report.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.gamepadState(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(withID?.faceButtonMask == 0x90)
        #expect(withID?.leftStickX == 32)
        #expect(withID?.leftStickY == 64)
        #expect(withID?.rightStickX == 192)
        #expect(withID?.rightStickY == 224)
        #expect(withID?.dpadDirectionMask == 0x03)
        #expect(withID?.shoulderButtonMask == 0x03)
        #expect(withID?.auxiliaryButtonMask == 0xf0)
        #expect(withID?.leftTriggerValue == 180)
        #expect(withID?.rightTriggerValue == 90)
        #expect(withID?.playStationButtonPressed == true)
        #expect(withID?.touchpadButtonPressed == true)
        #expect(withID?.microphoneButtonPressed == true)
        #expect(withID?.microphoneMuted == true)
        #expect(withID?.headphonesConnected == false)
        #expect(withID?.microphoneConnected == false)
        #expect(withID?.externalMicrophoneActive == true)
        #expect(withID?.primaryTouch.isActive == true)
        #expect(withID?.primaryTouch.contactID == 3)
        #expect(withID?.primaryTouch.x == 1_500)
        #expect(withID?.primaryTouch.y == 300)
        #expect(withID?.primaryTouch.normalizedX ?? 0 > 0)
        #expect(withID?.primaryTouch.normalizedY ?? 0 > 0)
        #expect(withID?.secondaryTouch.isActive == false)

        let withoutReportID = Array(report.dropFirst()).withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.gamepadState(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(withoutReportID == withID)
    }

    @Test func usbGamepadStateParsesTheSharedControllerPayload() {
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 0x01
        report[1] = 16
        report[2] = 48
        report[3] = 208
        report[4] = 240
        report[5] = 200 // L2 analog value.
        report[6] = 150 // R2 analog value.
        report[8] = 0x28 // Cross + neutral D-pad.
        report[9] = 0x90 // Create + R3.
        report[10] = 0x05 // PS + microphone button.
        writeTouchPoint(contact: 7, x: 1_100, y: 500, at: 33, in: &report)
        writeTouchPoint(contact: 8 | 0x80, x: 400, y: 800, at: 37, in: &report)

        let withID = report.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.usbGamepadState(
                reportID: 0x01,
                bytes: $0
            )
        }
        #expect(withID?.faceButtonMask == 0x20)
        #expect(withID?.leftStickX == 16)
        #expect(withID?.leftStickY == 48)
        #expect(withID?.rightStickX == 208)
        #expect(withID?.rightStickY == 240)
        #expect(withID?.dpadDirectionMask == 0)
        #expect(withID?.auxiliaryButtonMask == 0x90)
        #expect(withID?.leftTriggerValue == 200)
        #expect(withID?.rightTriggerValue == 150)
        #expect(withID?.playStationButtonPressed == true)
        #expect(withID?.touchpadButtonPressed == false)
        #expect(withID?.microphoneButtonPressed == true)
        #expect(withID?.primaryTouch.contactID == 7)
        #expect(withID?.primaryTouch.x == 1_100)
        #expect(withID?.primaryTouch.y == 500)

        let withoutReportID = Array(report.dropFirst()).withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.usbGamepadState(
                reportID: 0x01,
                bytes: $0
            )
        }
        #expect(withoutReportID == withID)
    }

    @Test func microphoneFeedbackIsNotParsedAsGamepadState() {
        var report = [UInt8](repeating: 0, count: 78)
        report[0] = 0x31
        report[1] = 0x02 // microphone feedback flag
        report[3] = 0xd4
        report[4] = 0xff

        let state = report.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.gamepadState(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(state == nil)

        // The same bytes without the flag are ordinary controller state, even
        // when the Y axis happens to sit on the audio TOC value.
        report[1] = 0x00
        let stickState = report.withUnsafeBufferPointer {
            DualSenseBluetoothAudioPacketBuilder.gamepadState(
                reportID: 0x31,
                bytes: $0
            )
        }
        #expect(stickState != nil)
    }

    private func writeTouchPoint(
        contact: UInt8,
        x: UInt16,
        y: UInt16,
        at offset: Int,
        in report: inout [UInt8]
    ) {
        report[offset] = contact
        report[offset + 1] = UInt8(truncatingIfNeeded: x)
        report[offset + 2] = UInt8(truncatingIfNeeded: x >> 8)
            | (UInt8(truncatingIfNeeded: y) << 4)
        report[offset + 3] = UInt8(truncatingIfNeeded: y >> 4)
    }
}
