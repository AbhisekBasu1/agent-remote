import Foundation

public struct DualSenseBluetoothTouchPoint: Equatable, Sendable {
    public static let width = 1_920
    public static let height = 1_080

    public let isActive: Bool
    public let contactID: UInt8
    public let x: UInt16
    public let y: UInt16

    public var normalizedX: Double {
        guard isActive else { return 0 }
        return (Double(x) / Double(Self.width - 1)) * 2 - 1
    }

    /// GameController presents upward movement as positive. Raw DualSense Y
    /// grows downward, so invert it while normalizing.
    public var normalizedY: Double {
        guard isActive else { return 0 }
        return 1 - (Double(y) / Double(Self.height - 1)) * 2
    }
}

public struct DualSenseBluetoothGamepadState: Equatable, Sendable {
    public let leftStickX: UInt8
    public let leftStickY: UInt8
    public let rightStickX: UInt8
    public let rightStickY: UInt8
    public let faceButtonMask: UInt8
    public let dpadDirectionMask: UInt8
    public let shoulderButtonMask: UInt8
    public let auxiliaryButtonMask: UInt8
    public let leftTriggerValue: UInt8
    public let rightTriggerValue: UInt8
    public let playStationButtonPressed: Bool
    public let touchpadButtonPressed: Bool
    public let microphoneButtonPressed: Bool
    public let microphoneMuted: Bool
    public let headphonesConnected: Bool
    public let microphoneConnected: Bool
    public let externalMicrophoneActive: Bool
    public let primaryTouch: DualSenseBluetoothTouchPoint
    public let secondaryTouch: DualSenseBluetoothTouchPoint
}

public struct DualSenseBluetoothMicrophonePacket: Equatable, Sendable {
    public let counter: UInt8
    public let opusFrame: Data

    public init(counter: UInt8, opusFrame: Data) {
        self.counter = counter
        self.opusFrame = opusFrame
    }
}

/// Packet construction and parsing for the DualSense's proprietary Bluetooth
/// audio-over-HID transport. Reports are protected with Sony's CRC32 variant.
public struct DualSenseBluetoothAudioPacketBuilder: Sendable {
    /// Report 0x32 is the controller's compact microphone-stream control
    /// report. A microphone-only client does not need to send speaker or
    /// haptics audio continuously; one enable report starts the return stream
    /// and one disable report stops it.
    public static let audioReportLength = 142
    public static let microphoneArmingReportLength = 398
    public static let fullAudioReportLength = 547
    public static let controlReportLength = 78
    public static let microphoneFrameSamples = 480
    public static let microphoneSampleRate = 48_000

    private var sequence: UInt8 = 0
    private var audioPacketCounter: UInt8 = 0

    /// Sony's known-good 63-byte Bluetooth SetStateData baseline used by the
    /// microphone bridge firmware. The 0x36 transport requires this full state
    /// subreport; a sparse validity block is accepted by HID but does not arm
    /// the microphone on every controller firmware revision.
    ///
    /// Keep LED ownership out of this load-bearing audio state. Mixing
    /// AllowLedColor into the same compound report correlated with the
    /// controller returning encoded silence. A separate minimal report below
    /// sets the lightbar without touching any audio-validity bits.
    private static let microphoneArmingState: [UInt8] = [
        0xfd, 0xf3, 0x00, 0x00, 0x7f, 0x64, 0x40, 0x09,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x07, 0x00,
        0x00, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]

    public init() {}

    public static func setupReport(sequence: UInt8 = 0) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: controlReportLength)
        report[0] = 0x31
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x10 // required Sony Bluetooth output tag
        report[3] = 0xa0
        report[4] = 0x80
        report[8] = 0x64
        report[10] = 0x30
        report[40] = 0x02
        appendCRC(to: &report, payloadLength: 74)
        return report
    }

    /// Sets the controller's physical microphone mute latch and matching LED.
    /// Keep this report deliberately minimal: Sony's driver marks only the
    /// mute-light and power-save fields valid. Mixing unrelated audio controls
    /// into the same state update can make controller firmware ignore it.
    public static func microphoneStateReport(
        muted: Bool,
        sequence: UInt8 = 0
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: controlReportLength)
        report[0] = 0x31
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x10 // required Sony Bluetooth output tag

        // Common SetState data begins at byte three.
        report[4] = 0x03 // mute LED and power-save/mute are valid
        report[11] = muted ? 0x01 : 0x00 // physical mute LED
        report[12] = muted ? 0x10 : 0x00 // MicMute power-save bit
        appendCRC(to: &report, payloadLength: 74)
        return report
    }

    public mutating func microphoneStateReport(muted: Bool) -> [UInt8] {
        let report = Self.microphoneStateReport(
            muted: muted,
            sequence: sequence
        )
        sequence = (sequence + 1) & 0x0f
        return report
    }

    /// Changes only the Bluetooth lightbar color. Audio routing and mute
    /// fields remain invalid and therefore cannot be overwritten as a side
    /// effect of providing microphone-mode feedback.
    public static func lightbarColorReport(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        sequence: UInt8 = 0
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: controlReportLength)
        report[0] = 0x31
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x10
        report[4] = 0x04 // SetState byte 1: AllowLedColor only
        report[47] = red
        report[48] = green
        report[49] = blue
        appendCRC(to: &report, payloadLength: 74)
        return report
    }

    public mutating func lightbarColorReport(
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> [UInt8] {
        let report = Self.lightbarColorReport(
            red: red,
            green: green,
            blue: blue,
            sequence: sequence
        )
        sequence = (sequence + 1) & 0x0f
        return report
    }

    /// Drives classic dual-motor rumble. SetState byte 0 selects Sony's
    /// vibration-emulation haptics (bit 1) and marks the compatible-vibration
    /// motors valid (bit 0); every audio, LED, and mute validity bit stays
    /// clear so agent feedback can never overwrite a microphone route. Rumble
    /// is sticky until the next report, so callers must end with zero motors.
    public static func rumbleReport(
        lowFrequencyMotor: UInt8,
        highFrequencyMotor: UInt8,
        sequence: UInt8 = 0
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: controlReportLength)
        report[0] = 0x31
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x10
        report[3] = 0x03 // SetState byte 0: HapticsSelect | CompatibleVibration
        report[5] = highFrequencyMotor
        report[6] = lowFrequencyMotor
        appendCRC(to: &report, payloadLength: 74)
        return report
    }

    public mutating func rumbleReport(
        lowFrequencyMotor: UInt8,
        highFrequencyMotor: UInt8
    ) -> [UInt8] {
        let report = Self.rumbleReport(
            lowFrequencyMotor: lowFrequencyMotor,
            highFrequencyMotor: highFrequencyMotor,
            sequence: sequence
        )
        sequence = (sequence + 1) & 0x0f
        return report
    }

    /// Changes only the five player-indicator LEDs. Like the lightbar
    /// report, it marks a single validity bit so session slots can never
    /// disturb audio routing, the mute latch, or the lightbar color.
    public static func playerLEDReport(
        mask: UInt8,
        immediate: Bool = false,
        sequence: UInt8 = 0
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: controlReportLength)
        report[0] = 0x31
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x10
        report[4] = 0x10 // SetState byte 1: AllowPlayerIndicators only
        // Bits 0...4 select the five indicators. Bit 5 tells the controller
        // to apply the mask immediately instead of cross-fading from the old
        // one, which otherwise makes rapid focus changes look like several
        // unrelated lights are selected at once.
        report[46] = (mask & 0x1f) | (immediate ? 0x20 : 0)
        appendCRC(to: &report, payloadLength: 74)
        return report
    }

    public mutating func playerLEDReport(
        mask: UInt8,
        immediate: Bool = false
    ) -> [UInt8] {
        let report = Self.playerLEDReport(
            mask: mask,
            immediate: immediate,
            sequence: sequence
        )
        sequence = (sequence + 1) & 0x0f
        return report
    }

    /// USB output report 0x02 carries the same 47-byte SetStateData block as
    /// Bluetooth 0x31, but with no sequence byte, output tag, or CRC, so each
    /// SetState offset lands at report index `offset + 1`.
    public static let usbOutputReportLength = 63

    public static func usbLightbarColorReport(
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: usbOutputReportLength)
        report[0] = 0x02
        report[2] = 0x04 // SetState byte 1: AllowLedColor only
        report[45] = red
        report[46] = green
        report[47] = blue
        return report
    }

    public static func usbRumbleReport(
        lowFrequencyMotor: UInt8,
        highFrequencyMotor: UInt8
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: usbOutputReportLength)
        report[0] = 0x02
        report[1] = 0x03 // SetState byte 0: HapticsSelect | CompatibleVibration
        report[3] = highFrequencyMotor
        report[4] = lowFrequencyMotor
        return report
    }

    public static func usbPlayerLEDReport(
        mask: UInt8,
        immediate: Bool = false
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: usbOutputReportLength)
        report[0] = 0x02
        report[2] = 0x10 // SetState byte 1: AllowPlayerIndicators only
        report[44] = (mask & 0x1f) | (immediate ? 0x20 : 0)
        return report
    }

    /// Selects the controller's built-in microphone and restores the capture
    /// path used by Sony's own state block. In particular, the internal array
    /// needs beamforming enabled; selecting the source without that bit can
    /// produce valid 71-byte Opus packets containing only encoded silence.
    public static func internalMicrophoneSourceReport(
        microphoneVolume: UInt8 = 0x40,
        audioControl: UInt8 = 0x09,
        audioControl2: UInt8 = 0x0a,
        sequence: UInt8 = 0
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: controlReportLength)
        report[0] = 0x31
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x10
        report[3] = 0xc0 // mic volume and AudioControl are valid
        report[4] = 0x80 // AudioControl2 is valid
        report[9] = min(microphoneVolume, 0x40)
        report[10] = audioControl
        report[40] = audioControl2
        appendCRC(to: &report, payloadLength: 74)
        return report
    }

    public mutating func internalMicrophoneSourceReport(
        microphoneVolume: UInt8 = 0x40,
        audioControl: UInt8 = 0x09,
        audioControl2: UInt8 = 0x0a
    ) -> [UInt8] {
        let report = Self.internalMicrophoneSourceReport(
            microphoneVolume: microphoneVolume,
            audioControl: audioControl,
            audioControl2: audioControl2,
            sequence: sequence
        )
        sequence = (sequence + 1) & 0x0f
        return report
    }

    public mutating func audioReport(microphoneEnabled: Bool) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: Self.audioReportLength)
        report[0] = 0x32
        report[1] = (sequence & 0x0f) << 4

        // 0x11 configuration sub-packet. Only the two stream-state bits are
        // present, hence payload length 1. Bit zero enables microphone return;
        // bit one remains set in both states. Sending the older 0xff/0xfe mask
        // with seven payload bytes makes some firmware return encoded silence.
        report[2] = 0x91
        report[3] = 1
        report[4] = microphoneEnabled ? 0x03 : 0x02

        Self.appendCRC(to: &report, payloadLength: 138)
        sequence = (sequence + 1) & 0x0f
        return report
    }

    /// Builds the controller's genuine two-frame Bluetooth audio carrier. The
    /// haptics channels contain zeroes and each speaker channel contains a
    /// valid 10 ms, 160-kbit/s stereo Opus silence packet. Some controller
    /// firmware requires this audio clock before it returns microphone frames,
    /// even for a microphone-only host.
    public mutating func fullAudioReport(microphoneEnabled: Bool) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: Self.fullAudioReportLength)
        report[0] = 0x39
        report[1] = (sequence & 0x0f) << 4

        // Configuration sub-packet: stream state, four buffer lengths, then
        // the controller audio packet counter.
        report[2] = 0x91
        report[3] = 6
        report[4] = microphoneEnabled ? 0x7f : 0x7e
        report[5] = 64
        report[6] = 64
        report[7] = 64
        report[8] = 64
        audioPacketCounter &+= 2
        report[9] = audioPacketCounter

        // Two 64-byte zero haptics frames.
        report[10] = 0xd2
        report[11] = 64

        // Two 200-byte speaker frames. With the Opus encoder configured for
        // 48 kHz stereo, 10 ms, 160 kbit/s, CBR and complexity zero, encoded
        // silence is f4 ff fe followed by zero padding.
        report[140] = 0xd3
        report[141] = 200
        report[142] = 0xf4
        report[143] = 0xff
        report[144] = 0xfe
        report[342] = 0xf4
        report[343] = 0xff
        report[344] = 0xfe

        Self.appendCRC(to: &report, payloadLength: 543)
        sequence = (sequence + 1) & 0x0f
        return report
    }

    /// Builds the microphone-only 0x36 arming report used by the open-source
    /// DS5Dongle microphone implementation. It carries a stream-control
    /// subreport, a minimal SetStateData block that restores the built-in mic
    /// path, and one silent haptics block. No speaker/Opus output is present.
    /// Once armed, the controller's microphone stream is sticky, so callers
    /// should resend this only while feedback frames are absent.
    public mutating func microphoneArmingReport(
        microphoneVolume: UInt8 = 0x40
    ) -> [UInt8] {
        var report = [UInt8](
            repeating: 0,
            count: Self.microphoneArmingReportLength
        )
        report[0] = 0x36
        report[1] = (sequence & 0x0f) << 4

        // Packet 0x11: microphone enabled plus the five documented audio
        // buffer fields and the controller audio packet counter.
        report[2] = 0x91
        report[3] = 7
        report[4] = 0xff
        report[5] = 64
        report[6] = 64
        report[7] = 64
        report[8] = 64
        report[9] = 64
        audioPacketCounter &+= 1
        report[10] = audioPacketCounter

        // Packet 0x10: the complete, known-good 63-byte SetStateData block.
        // The bridge firmware calls this subreport load-bearing; sparse state
        // variants are accepted by HID but fail to arm some controller builds.
        // VolumeMic (offset 6) must agree with the separate 0x31 source
        // report, or this later report silently overrides the selected gain
        // and invalidates any gain experiment.
        report[11] = 0x90
        report[12] = 63
        var state = Self.microphoneArmingState
        state[6] = min(microphoneVolume, 0x40)
        report.replaceSubrange(13..<76, with: state)

        // Packet 0x12: one silent 64-byte haptics block. The speaker lane is
        // intentionally omitted; fabricated speaker padding can invalidate
        // the entire microphone arming transaction on some firmware.
        report[76] = 0x92
        report[77] = 64

        Self.appendCRC(to: &report, payloadLength: 394)
        sequence = (sequence + 1) & 0x0f
        return report
    }

    /// Length of one Opus microphone packet inside a 0x31 feedback report.
    public static let microphoneOpusPacketLength = 71

    /// Sony tags microphone feedback by setting bit 1 of the flag byte that
    /// follows the 0x31 report ID; the Opus payload starts two bytes later,
    /// after the audio packet counter. Both working DS5Dongle implementations
    /// classify on this bit alone. Never classify on packet content: a voice
    /// frame is 0xd4 followed by arbitrary range-coder bytes, and matching on
    /// the 0xd4 0xff 0xfe encoded-silence prefix admits only silent frames.
    private static func microphoneFlagIsSet(
        bytes: UnsafeBufferPointer<UInt8>,
        includesReportID: Bool
    ) -> Bool {
        let flagIndex = includesReportID ? 1 : 0
        guard bytes.count > flagIndex else { return false }
        return bytes[flagIndex] & 0x02 != 0
    }

    /// Extracts an Opus mic frame and its controller-generation counter from
    /// an input report. IOHID can deliver the report either with or without
    /// the report-ID byte, so both layouts are accepted.
    public static func microphonePacket(
        reportID: UInt32,
        bytes: UnsafeBufferPointer<UInt8>
    ) -> DualSenseBluetoothMicrophonePacket? {
        guard reportID == 0x31 else { return nil }
        let includesReportID = bytes.first == 0x31
        guard microphoneFlagIsSet(
            bytes: bytes,
            includesReportID: includesReportID
        ) else {
            return nil
        }

        let counterIndex = (includesReportID ? 1 : 0) + 1
        let payloadIndex = counterIndex + 1
        guard bytes.count >= payloadIndex + microphoneOpusPacketLength else {
            return nil
        }
        return DualSenseBluetoothMicrophonePacket(
            counter: bytes[counterIndex],
            opusFrame: Data(
                bytes[payloadIndex..<payloadIndex + microphoneOpusPacketLength]
            )
        )
    }

    /// Compatibility helper for callers that do not need loss accounting.
    public static func microphoneOpusFrame(
        reportID: UInt32,
        bytes: UnsafeBufferPointer<UInt8>
    ) -> Data? {
        microphonePacket(reportID: reportID, bytes: bytes)?.opusFrame
    }

    /// Returns the four face-button bits from a genuine full gamepad report,
    /// or nil for microphone/audio feedback frames. Audio detection uses the
    /// feedback flag bit, so stick positions that merely resemble an Opus TOC
    /// byte can no longer drop button transitions.
    public static func faceButtonMask(
        reportID: UInt32,
        bytes: UnsafeBufferPointer<UInt8>
    ) -> UInt8? {
        guard reportID == 0x31 else { return nil }
        let includesReportID = bytes.first == 0x31
        guard !microphoneFlagIsSet(
            bytes: bytes,
            includesReportID: includesReportID
        ) else {
            return nil
        }

        let buttonIndex = includesReportID ? 10 : 9
        guard bytes.count > buttonIndex else { return nil }
        return bytes[buttonIndex] & 0xf0
    }

    /// Parses the normal controller state that shares report 0x31 with mic
    /// feedback. The layout is Sony's 63-byte common DualSense input payload,
    /// preceded by the Bluetooth sequence header. Audio feedback is rejected.
    public static func gamepadState(
        reportID: UInt32,
        bytes: UnsafeBufferPointer<UInt8>
    ) -> DualSenseBluetoothGamepadState? {
        guard reportID == 0x31 else { return nil }
        let includesReportID = bytes.first == 0x31
        let commonStart = includesReportID ? 2 : 1
        guard bytes.count >= commonStart + 55 else { return nil }

        // Microphone feedback shares this report ID; reject it by its flag
        // bit rather than by content so ordinary stick positions cannot be
        // mistaken for audio.
        guard !microphoneFlagIsSet(
            bytes: bytes,
            includesReportID: includesReportID
        ) else {
            return nil
        }

        return parsedGamepadState(bytes: bytes, commonStart: commonStart)
    }

    /// Parses the standard 64-byte USB input report. USB and Bluetooth share
    /// Sony's common controller payload; Bluetooth adds a transport byte and
    /// CRC around it, while USB begins directly with report ID 0x01.
    public static func usbGamepadState(
        reportID: UInt32,
        bytes: UnsafeBufferPointer<UInt8>
    ) -> DualSenseBluetoothGamepadState? {
        guard reportID == 0x01 else { return nil }
        let includesReportID = bytes.first == 0x01
        let commonStart = includesReportID ? 1 : 0
        guard bytes.count >= commonStart + 55 else { return nil }
        return parsedGamepadState(bytes: bytes, commonStart: commonStart)
    }

    public static func crc32Sony(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        crc = updateCRC(crc, byte: 0xa2)
        for byte in bytes {
            crc = updateCRC(crc, byte: byte)
        }
        return crc ^ 0xffff_ffff
    }

    private static func appendCRC(to report: inout [UInt8], payloadLength: Int) {
        let crc = crc32Sony(report[..<payloadLength])
        report[payloadLength] = UInt8(truncatingIfNeeded: crc)
        report[payloadLength + 1] = UInt8(truncatingIfNeeded: crc >> 8)
        report[payloadLength + 2] = UInt8(truncatingIfNeeded: crc >> 16)
        report[payloadLength + 3] = UInt8(truncatingIfNeeded: crc >> 24)
    }

    private static func parsedGamepadState(
        bytes: UnsafeBufferPointer<UInt8>,
        commonStart: Int
    ) -> DualSenseBluetoothGamepadState {
        let leftStickX = bytes[commonStart]
        let leftStickY = bytes[commonStart + 1]
        let rightStickX = bytes[commonStart + 2]
        let rightStickY = bytes[commonStart + 3]
        let leftTrigger = bytes[commonStart + 4]
        let rightTrigger = bytes[commonStart + 5]
        let buttons0 = bytes[commonStart + 7]
        let buttons1 = bytes[commonStart + 8]
        let buttons2 = bytes[commonStart + 9]
        let touchStart = commonStart + 32
        let status1 = bytes[commonStart + 53]
        let status2 = bytes[commonStart + 54]

        return DualSenseBluetoothGamepadState(
            leftStickX: leftStickX,
            leftStickY: leftStickY,
            rightStickX: rightStickX,
            rightStickY: rightStickY,
            faceButtonMask: buttons0 & 0xf0,
            dpadDirectionMask: dpadDirectionMask(hatValue: buttons0 & 0x0f),
            shoulderButtonMask: buttons1 & 0x03,
            auxiliaryButtonMask: buttons1 & 0xf0,
            leftTriggerValue: leftTrigger,
            rightTriggerValue: rightTrigger,
            playStationButtonPressed: buttons2 & 0x01 != 0,
            touchpadButtonPressed: buttons2 & 0x02 != 0,
            microphoneButtonPressed: buttons2 & 0x04 != 0,
            microphoneMuted: status1 & 0x04 != 0,
            headphonesConnected: status1 & 0x01 != 0,
            microphoneConnected: status1 & 0x02 != 0,
            externalMicrophoneActive: status2 & 0x01 != 0,
            primaryTouch: touchPoint(bytes: bytes, offset: touchStart),
            secondaryTouch: touchPoint(bytes: bytes, offset: touchStart + 4)
        )
    }

    /// Converts Sony's eight-way hat value into independent direction bits:
    /// Up, Right, Down, Left. Diagonals intentionally set two bits.
    private static func dpadDirectionMask(hatValue: UInt8) -> UInt8 {
        switch hatValue {
        case 0: return 0x01
        case 1: return 0x01 | 0x02
        case 2: return 0x02
        case 3: return 0x02 | 0x04
        case 4: return 0x04
        case 5: return 0x04 | 0x08
        case 6: return 0x08
        case 7: return 0x08 | 0x01
        default: return 0
        }
    }

    private static func touchPoint(
        bytes: UnsafeBufferPointer<UInt8>,
        offset: Int
    ) -> DualSenseBluetoothTouchPoint {
        let contact = bytes[offset]
        let packedMiddle = bytes[offset + 2]
        let x = UInt16(bytes[offset + 1])
            | (UInt16(packedMiddle & 0x0f) << 8)
        let y = UInt16(packedMiddle >> 4)
            | (UInt16(bytes[offset + 3]) << 4)
        return DualSenseBluetoothTouchPoint(
            isActive: contact & 0x80 == 0,
            contactID: contact & 0x7f,
            x: x,
            y: y
        )
    }

    private static func updateCRC(_ crc: UInt32, byte: UInt8) -> UInt32 {
        var value = crc ^ UInt32(byte)
        for _ in 0..<8 {
            if value & 1 == 1 {
                value = (value >> 1) ^ 0xedb8_8320
            } else {
                value >>= 1
            }
        }
        return value
    }
}
