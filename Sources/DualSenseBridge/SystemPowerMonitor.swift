import Foundation
import IOKit
import IOKit.pwr_mgt

// Swift cannot import IOMessage.h's `iokit_common_msg(...)` macros. These are
// the public constants produced by that macro for the three messages we use.
private let messageCanSystemSleep: natural_t = 0xe000_0270
private let messageSystemWillSleep: natural_t = 0xe000_0280
private let messageSystemHasPoweredOn: natural_t = 0xe000_0300

private func agentRemoteSystemPowerCallback(
    refcon: UnsafeMutableRawPointer?,
    service _: io_service_t,
    messageType: natural_t,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<SystemPowerMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .handle(messageType: messageType, argument: messageArgument)
}

/// Receives the non-abortable system-sleep notification directly from IOKit.
///
/// Releasing a seized DualSense causes macOS's native HID client to publish one
/// handoff event. If the computer enters sleep in that same instant, macOS sees
/// the event as fresh user activity and immediately wakes again. IOKit permits
/// applications to acknowledge `kIOMessageSystemWillSleep` asynchronously, so
/// Agent Remote releases the controller, gives that handoff event a brief
/// moment to settle, and only then lets the already-approved sleep continue.
final class SystemPowerMonitor {
    static let controllerHandoffSettleDelay: TimeInterval = 1.5

    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var connection: io_connect_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL
    private var pendingAcknowledgementID: Int?
    private var pendingAcknowledgement: DispatchWorkItem?

    func start() {
        guard connection == IO_OBJECT_NULL else { return }

        var port: IONotificationPortRef?
        var newNotifier: io_object_t = IO_OBJECT_NULL
        let newConnection = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &port,
            agentRemoteSystemPowerCallback,
            &newNotifier
        )
        guard newConnection != IO_OBJECT_NULL, let port else {
            if newNotifier != IO_OBJECT_NULL {
                IOObjectRelease(newNotifier)
            }
            DiagnosticLog.write(
                "system power monitor unavailable; sleep handoff protection disabled"
            )
            return
        }

        connection = newConnection
        notificationPort = port
        notifier = newNotifier
        IONotificationPortSetDispatchQueue(port, .main)
        DiagnosticLog.write("system power monitor ready")
    }

    func stop() {
        acknowledgePendingSleepImmediately()

        if notifier != IO_OBJECT_NULL {
            _ = IODeregisterForSystemPower(&notifier)
            notifier = IO_OBJECT_NULL
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if connection != IO_OBJECT_NULL {
            IOServiceClose(connection)
            connection = IO_OBJECT_NULL
        }
    }

    fileprivate func handle(
        messageType: natural_t,
        argument: UnsafeMutableRawPointer?
    ) {
        switch messageType {
        case messageCanSystemSleep:
            acknowledge(notificationID: Int(bitPattern: argument))

        case messageSystemWillSleep:
            acknowledgePendingSleepImmediately()
            onWillSleep?()
            scheduleSleepAcknowledgement(
                notificationID: Int(bitPattern: argument)
            )

        case messageSystemHasPoweredOn:
            pendingAcknowledgement?.cancel()
            pendingAcknowledgement = nil
            pendingAcknowledgementID = nil
            onDidWake?()

        default:
            break
        }
    }

    private func scheduleSleepAcknowledgement(notificationID: Int) {
        pendingAcknowledgementID = notificationID
        let acknowledgement = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingAcknowledgementID == notificationID else {
                return
            }
            self.pendingAcknowledgement = nil
            self.pendingAcknowledgementID = nil
            let result = self.acknowledge(notificationID: notificationID)
            DiagnosticLog.write(
                "controller HID handoff settled; sleep acknowledged, result=\(result)"
            )
        }
        pendingAcknowledgement = acknowledgement
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.controllerHandoffSettleDelay,
            execute: acknowledgement
        )
    }

    private func acknowledgePendingSleepImmediately() {
        pendingAcknowledgement?.cancel()
        pendingAcknowledgement = nil
        guard let notificationID = pendingAcknowledgementID else { return }
        pendingAcknowledgementID = nil
        _ = acknowledge(notificationID: notificationID)
    }

    @discardableResult
    private func acknowledge(notificationID: Int) -> IOReturn {
        guard connection != IO_OBJECT_NULL else { return kIOReturnNotOpen }
        return IOAllowPowerChange(connection, notificationID)
    }
}
