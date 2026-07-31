import Foundation
import Testing
@testable import DualSenseBridgeCore

private func expectValidSonyCRC(_ report: [UInt8], payloadLength: Int) {
    let crc = DualSenseBluetoothAudioPacketBuilder.crc32Sony(report[..<payloadLength])
    #expect(report[payloadLength] == UInt8(truncatingIfNeeded: crc))
    #expect(report[payloadLength + 1] == UInt8(truncatingIfNeeded: crc >> 8))
    #expect(report[payloadLength + 2] == UInt8(truncatingIfNeeded: crc >> 16))
    #expect(report[payloadLength + 3] == UInt8(truncatingIfNeeded: crc >> 24))
}

@Test func bluetoothRumbleReportDrivesOnlyTheMotors() {
    let report = DualSenseBluetoothAudioPacketBuilder.rumbleReport(
        lowFrequencyMotor: 0xaa,
        highFrequencyMotor: 0x55,
        sequence: 3
    )

    #expect(report.count == DualSenseBluetoothAudioPacketBuilder.controlReportLength)
    #expect(report[0] == 0x31)
    #expect(report[1] == 3 << 4)
    #expect(report[2] == 0x10)
    #expect(report[3] == 0x03)
    #expect(report[5] == 0x55)
    #expect(report[6] == 0xaa)
    expectValidSonyCRC(report, payloadLength: 74)

    // Every audio, LED, and mute validity field must stay clear so an agent
    // alert can never overwrite the microphone route or mute latch.
    #expect(report[4] == 0x00)
    for index in 7..<74 {
        #expect(report[index] == 0x00)
    }
}

@Test func bluetoothRumbleReportAdvancesTheSharedSequence() {
    var builder = DualSenseBluetoothAudioPacketBuilder()
    let first = builder.rumbleReport(lowFrequencyMotor: 10, highFrequencyMotor: 5)
    let second = builder.rumbleReport(lowFrequencyMotor: 10, highFrequencyMotor: 5)
    #expect(first[1] == 0 << 4)
    #expect(second[1] == 1 << 4)
}

@Test func usbLightbarReportMatchesTheBluetoothSetStateLayout() {
    let bluetooth = DualSenseBluetoothAudioPacketBuilder.lightbarColorReport(
        red: 0x11,
        green: 0x22,
        blue: 0x33
    )
    let usb = DualSenseBluetoothAudioPacketBuilder.usbLightbarColorReport(
        red: 0x11,
        green: 0x22,
        blue: 0x33
    )

    #expect(usb.count == DualSenseBluetoothAudioPacketBuilder.usbOutputReportLength)
    #expect(usb[0] == 0x02)
    // USB places SetState offset n at index n+1; Bluetooth places it at n+3.
    // The same AllowLedColor flag and RGB bytes must land in both layouts.
    #expect(usb[2] == bluetooth[4])
    #expect(usb[2] == 0x04)
    #expect(usb[45] == bluetooth[47])
    #expect(usb[46] == bluetooth[48])
    #expect(usb[47] == bluetooth[49])
    #expect(usb[1] == 0x00)
    #expect(usb[3] == 0x00)
    #expect(usb[4] == 0x00)
}

@Test func usbRumbleReportDrivesOnlyTheMotors() {
    let report = DualSenseBluetoothAudioPacketBuilder.usbRumbleReport(
        lowFrequencyMotor: 0xcc,
        highFrequencyMotor: 0x44
    )

    #expect(report.count == DualSenseBluetoothAudioPacketBuilder.usbOutputReportLength)
    #expect(report[0] == 0x02)
    #expect(report[1] == 0x03)
    #expect(report[3] == 0x44)
    #expect(report[4] == 0xcc)
    #expect(report[2] == 0x00)
    for index in 5..<report.count {
        #expect(report[index] == 0x00)
    }
}
