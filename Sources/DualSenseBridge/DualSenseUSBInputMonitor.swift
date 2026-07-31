import CoreFoundation
import DualSenseBridgeCore
import Foundation
import IOKit.hid

/// Owns the wired DualSense HID interface and forwards Sony's complete input
/// report. Exclusive access is important for two controls that GameController
/// does not reliably deliver to apps: Mute, and the system-owned PS button.
/// The controller's separate USB audio interface remains available to Core
/// Audio while its game-controller HID interface is isolated here.
final class DualSenseUSBInputMonitor {
    var onGamepadState: ((DualSenseBluetoothGamepadState) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    private var manager = IOHIDManagerCreate(
        kCFAllocatorDefault,
        IOOptionBits(kIOHIDOptionsTypeNone)
    )
    private var devices: [ObjectIdentifier: IOHIDDevice] = [:]
    private var isStarted = false
    private var managerIsOpen = false
    private var isSeizingDevice = false
    private var reportCount = 0

    var isConnected: Bool {
        !devices.isEmpty
    }

    var hasExclusiveAccess: Bool {
        isConnected && isSeizingDevice
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let isolatedResult = openFreshManager(exclusive: true)
        if isolatedResult == kIOReturnSuccess {
            DiagnosticLog.write(
                "USB DualSense HID isolated for complete button mapping"
            )
            return
        }

        let fallbackResult = openFreshManager(exclusive: false)
        if fallbackResult == kIOReturnSuccess {
            DiagnosticLog.write(
                "USB DualSense HID isolation unavailable (\(isolatedResult)); using GameController fallback"
            )
        } else {
            DiagnosticLog.write(
                "USB DualSense HID monitor failed: isolated=\(isolatedResult), normal=\(fallbackResult)"
            )
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        closeCurrentManager()
        devices.removeAll()
        reportCount = 0
    }

    /// USB report 0x02 marks only AllowLedColor valid, mirroring the
    /// Bluetooth LED-only report, so neither agent status nor microphone
    /// indicators can touch audio or mute state. Requires the seized
    /// interface; when isolation is unavailable the GameController fallback
    /// owns feedback instead.
    func setLightbar(red: UInt8, green: UInt8, blue: UInt8) {
        guard hasExclusiveAccess else { return }
        let result = send(
            DualSenseBluetoothAudioPacketBuilder.usbLightbarColorReport(
                red: red,
                green: green,
                blue: blue
            )
        )
        DiagnosticLog.write(
            "USB lightbar set to #\(String(format: "%02x%02x%02x", red, green, blue)), result=\(result)"
        )
    }

    func setRumble(lowFrequencyMotor: UInt8, highFrequencyMotor: UInt8) {
        guard hasExclusiveAccess else { return }
        let result = send(
            DualSenseBluetoothAudioPacketBuilder.usbRumbleReport(
                lowFrequencyMotor: lowFrequencyMotor,
                highFrequencyMotor: highFrequencyMotor
            )
        )
        if result != kIOReturnSuccess {
            DiagnosticLog.write("USB rumble report failed: \(result)")
        }
    }

    func setPlayerLEDs(mask: UInt8, immediate: Bool = false) {
        guard hasExclusiveAccess else { return }
        let result = send(
            DualSenseBluetoothAudioPacketBuilder.usbPlayerLEDReport(
                mask: mask,
                immediate: immediate
            )
        )
        if result == kIOReturnSuccess {
            DiagnosticLog.write(
                "USB player LEDs mask=0x\(String(format: "%02x", mask & 0x1f)), immediate=\(immediate)"
            )
        } else {
            DiagnosticLog.write("USB player LED report failed: \(result)")
        }
    }

    private func send(_ report: [UInt8]) -> IOReturn {
        guard let device = devices.values.first else { return kIOReturnNotFound }
        return report.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(report[0]),
                baseAddress,
                report.count
            )
        }
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice) {
        let identifier = ObjectIdentifier(device)
        guard devices[identifier] == nil else { return }
        let wasDisconnected = devices.isEmpty
        devices[identifier] = device
        DiagnosticLog.write(
            "USB DualSense raw HID attached; exclusive=\(isSeizingDevice)"
        )
        if wasDisconnected {
            onConnectionChanged?(true)
        }
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let wasConnected = !devices.isEmpty
        devices.removeValue(forKey: ObjectIdentifier(device))
        reportCount = 0
        DiagnosticLog.write("USB DualSense raw HID removed")
        if wasConnected, devices.isEmpty {
            onConnectionChanged?(false)
        }
    }

    fileprivate func inputReport(
        result: IOReturn,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex
    ) {
        guard result == kIOReturnSuccess, reportLength > 0 else { return }
        let bytes = UnsafeBufferPointer(start: report, count: Int(reportLength))
        guard let state = DualSenseBluetoothAudioPacketBuilder.usbGamepadState(
            reportID: reportID,
            bytes: bytes
        ) else {
            return
        }

        reportCount += 1
        if reportCount <= 3 {
            DiagnosticLog.write(
                "USB raw input report #\(reportCount), length=\(reportLength), leftStick=(\(state.leftStickX),\(state.leftStickY)), rightStick=(\(state.rightStickX),\(state.rightStickY)), face=0x\(String(format: "%02x", state.faceButtonMask)), dpad=0x\(String(format: "%02x", state.dpadDirectionMask)), auxiliary=0x\(String(format: "%02x", state.auxiliaryButtonMask))"
            )
        }
        onGamepadState?(state)
    }

    private func openFreshManager(exclusive: Bool) -> IOReturn {
        closeCurrentManager()
        devices.removeAll()
        reportCount = 0

        manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x054c,
            kIOHIDProductIDKey as String: 0x0ce6,
            kIOHIDTransportKey as String: "USB"
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            dualSenseUSBDeviceMatched,
            context
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            dualSenseUSBDeviceRemoved,
            context
        )
        IOHIDManagerRegisterInputReportCallback(
            manager,
            dualSenseUSBInputReport,
            context
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        let options = exclusive
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        let result = IOHIDManagerOpen(manager, options)
        guard result == kIOReturnSuccess else {
            unregisterAndUnscheduleManager()
            managerIsOpen = false
            isSeizingDevice = false
            return result
        }

        managerIsOpen = true
        isSeizingDevice = exclusive
        if let matched = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in matched {
                deviceMatched(device)
            }
        }
        return result
    }

    private func closeCurrentManager() {
        guard managerIsOpen else { return }
        unregisterAndUnscheduleManager()
        let options = isSeizingDevice
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        IOHIDManagerClose(manager, options)
        managerIsOpen = false
        isSeizingDevice = false
    }

    private func unregisterAndUnscheduleManager() {
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }
}

private func dualSenseUSBDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<DualSenseUSBInputMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .deviceMatched(device)
}

private func dualSenseUSBDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<DualSenseUSBInputMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .deviceRemoved(device)
}

private func dualSenseUSBInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard type == kIOHIDReportTypeInput, let context else { return }
    Unmanaged<DualSenseUSBInputMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .inputReport(
            result: result,
            reportID: reportID,
            report: report,
            reportLength: reportLength
        )
}
