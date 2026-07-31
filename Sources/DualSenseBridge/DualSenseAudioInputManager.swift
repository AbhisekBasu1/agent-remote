import CoreAudio
import DualSenseBridgeCore
import Foundation

enum DualSenseMicrophoneActivationResult: Equatable {
    case activated(name: String)
    case unavailable
    case failed(message: String)
}

/// Routes the controller microphone to apps that follow macOS's default input.
/// USB uses the DualSense's native Core Audio device. Bluetooth decodes Sony's
/// Opus-over-HID stream and writes it to any supported virtual loopback device.
final class DualSenseAudioInputManager {
    private static let bridgeDeviceUID = "DualSenseBridgeMic_UID"
    private static let previousDefaultInputUIDKey =
        "bluetoothMicrophone.previousDefaultInputUID.v1"

    private struct AudioDevice {
        let id: AudioDeviceID
        let name: String
        let manufacturer: String
        let uid: String
        let transportType: UInt32
        let hasInput: Bool
        let hasOutput: Bool
    }

    var onBluetoothFaceButtonMaskChanged: ((UInt8) -> Void)?
    var onBluetoothGamepadState: ((DualSenseBluetoothGamepadState) -> Void)?
    var onBluetoothConnectionChanged: ((Bool) -> Void)?
    /// Fires on the main queue after a microphone session — Bluetooth stream
    /// or USB dictation hold — has fully ended, so agent-status lightbar
    /// feedback can reclaim the LED from the session's own capture/finished
    /// indicators.
    var onMicrophoneSessionEnded: (() -> Void)?

    /// Microphone-session indicator colors, byte-identical to the Bluetooth
    /// session's LED-only reports so dictation looks the same on both
    /// transports: blue while capturing, amber once finished.
    private static let recordingLightbar: (red: UInt8, green: UInt8, blue: UInt8) = (0x00, 0x40, 0xff)
    private static let finishedLightbar: (red: UInt8, green: UInt8, blue: UInt8) = (0xff, 0xd7, 0x00)

    private let bluetoothHID: DualSenseBluetoothEnhancedModeEnabler
    private let usbHID: DualSenseUSBInputMonitor
    private var usbMicrophoneActivationCount = 0
    private var pendingUSBSessionEnd: DispatchWorkItem?
    private let pcmOutput = VirtualMicrophonePCMOutput()
    private let decodeQueue = DispatchQueue(
        label: "local.controllerproject.DualSenseBridge.opus-decode",
        qos: .userInteractive
    )
    private let decoderPreparationQueue = DispatchQueue(
        label: "local.controllerproject.DualSenseBridge.opus-prepare",
        qos: .utility
    )
    private let decoderPreparationLock = NSLock()
    private var decoder: BluetoothOpusDecoder?
    private var preparedDecoder: BluetoothOpusDecoder?
    private var decoderPreparationInFlight = false
    private var bluetoothActivationCount = 0
    private var savedDefaultInputID: AudioDeviceID?
    private var activeVirtualDeviceID: AudioDeviceID?
    private var pendingStop: DispatchWorkItem?
    private var decodedFrameCount = 0
    private var decodedNonSilentFrameCount = 0
    private var decodedMaximumPeak = 0
    private var droppedMicrophonePacketCount = 0

    init(
        bluetoothHID: DualSenseBluetoothEnhancedModeEnabler,
        usbHID: DualSenseUSBInputMonitor
    ) {
        self.bluetoothHID = bluetoothHID
        self.usbHID = usbHID

        bluetoothHID.onMicrophoneOpusFrame = { [weak self] frame, counter in
            self?.decode(frame, counter: counter)
        }
        bluetoothHID.onFaceButtonMaskChanged = { [weak self] mask in
            self?.onBluetoothFaceButtonMaskChanged?(mask)
        }
        bluetoothHID.onGamepadState = { [weak self] state in
            self?.onBluetoothGamepadState?(state)
        }
        bluetoothHID.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            if !connected {
                self.stopBluetoothMicrophone(restoreDefaultInput: true)
            }
            self.onBluetoothConnectionChanged?(connected)
        }
    }

    /// Repairs the system input after an app crash or forced restart while the
    /// temporary loopback microphone was selected. The bridge device has no
    /// producer outside an active controller route, so leaving it as the
    /// default would also silence the MacBook microphone for every other app.
    func restoreDefaultInputIfStranded() {
        guard let currentID = defaultInputDeviceID(),
              audioDevice(id: currentID)?.uid == Self.bridgeDeviceUID,
              let fallback = rememberedOrPhysicalFallbackInput() else {
            return
        }

        let status = setDefaultInputDevice(fallback.id)
        if status == noErr {
            unmuteIfSupported(deviceID: fallback.id)
            UserDefaults.standard.removeObject(
                forKey: Self.previousDefaultInputUIDKey
            )
            DiagnosticLog.write(
                "restored stranded default input to \(fallback.name)"
            )
        } else {
            DiagnosticLog.write(
                "could not restore stranded default input to \(fallback.name): \(status)"
            )
        }
    }

    /// Opens the project-owned virtual microphone during app startup and keeps
    /// its AudioQueue primed. Reopening the queue at shortcut-down added about
    /// 225 ms in the latest capture and clipped the first word; an already-live
    /// queue can emit silence until the controller's first real frame arrives.
    func prewarmBluetoothAudioPath() {
        // The first dlopen/symbol resolution for bundled libopus measured
        // 374 ms on this Mac. Do it during launch, not after a controller-button
        // press, and keep one fresh decoder ready for the next mic session.
        prewarmBluetoothDecoderSynchronously()

        guard dualSenseUSBInputDevice() == nil,
              !bluetoothHID.isMicrophoneStreaming,
              let virtual = supportedVirtualDevice() else {
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let status = pcmOutput.start(
            deviceID: virtual.id,
            deviceUID: virtual.uid
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        DiagnosticLog.write(
            String(
                format: "Bluetooth virtual microphone prepared and retained; status=%d, elapsed=%.3fs",
                status,
                elapsed
            )
        )
    }

    var isBluetoothConnected: Bool {
        bluetoothHID.isBluetoothConnected
    }

    var isUSBConnected: Bool {
        dualSenseUSBInputDevice() != nil
    }

    var hasExclusiveBluetoothAccess: Bool {
        bluetoothHID.hasExclusiveBluetoothAccess
    }

    var availableInputName: String? {
        if let usb = dualSenseUSBInputDevice() {
            return usb.name
        }
        guard bluetoothHID.isBluetoothConnected,
              let virtual = supportedVirtualDevice() else {
            return nil
        }
        return "DualSense BT Mic via \(virtual.name)"
    }

    var isDualSenseDefaultInput: Bool {
        guard let currentDefault = defaultInputDeviceID() else { return false }
        if let usb = dualSenseUSBInputDevice(), usb.id == currentDefault {
            return true
        }
        return bluetoothHID.isMicrophoneStreaming
            && activeVirtualDeviceID == currentDefault
    }

    var isBluetoothMicrophoneActive: Bool {
        bluetoothHID.isMicrophoneStreaming
    }

    func setBluetoothMicrophoneVolume(_ volume: UInt8) {
        bluetoothHID.setMicrophoneVolume(volume)
    }

    func setBluetoothMicrophoneSound(_ sound: BridgeSettings.BluetoothMicrophoneSound) {
        let preset: DualSenseBluetoothEnhancedModeEnabler.MicrophoneCapturePreset
        switch sound {
        case .natural:
            preset = .naturalBeamforming
        case .sonyVoiceChat:
            preset = .sonyVoiceChat
        case .naturalNoBeamforming:
            preset = .naturalNoBeamforming
        }
        bluetoothHID.setMicrophoneCapturePreset(preset)
    }

    func activate() -> DualSenseMicrophoneActivationResult {
        pendingStop?.cancel()
        pendingStop = nil

        if let input = dualSenseUSBInputDevice() {
            if bluetoothHID.isMicrophoneStreaming {
                stopBluetoothMicrophone(restoreDefaultInput: false)
            }
            let status = setDefaultInputDevice(input.id)
            guard status == noErr else {
                return .failed(message: "Core Audio error \(status)")
            }
            unmuteIfSupported(deviceID: input.id)
            beginUSBMicrophoneIndicator()
            return .activated(name: input.name)
        }

        guard bluetoothHID.isBluetoothConnected else {
            return .unavailable
        }
        guard let virtual = supportedVirtualDevice() else {
            return .failed(message:
                "Bluetooth audio was decoded, but no supported virtual microphone is installed."
            )
        }

        if bluetoothHID.isMicrophoneStreaming {
            bluetoothActivationCount += 1
            let status = setDefaultInputDevice(virtual.id)
            return status == noErr
                ? .activated(name: "DualSense BT Mic via \(virtual.name)")
                : .failed(message: "Core Audio error \(status)")
        }

        let newDecoder: BluetoothOpusDecoder
        if let readyDecoder = takePreparedBluetoothDecoder() {
            newDecoder = readyDecoder
            DiagnosticLog.write(
                "reusing prepared Bluetooth Opus decoder; decoder startup delay=0ms"
            )
            prepareBluetoothDecoderAsynchronously()
        } else {
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                newDecoder = try BluetoothOpusDecoder()
            } catch {
                return .failed(message: error.localizedDescription)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            DiagnosticLog.write(
                String(
                    format: "Bluetooth Opus decoder cold-created; elapsed=%.3fs",
                    elapsed
                )
            )
            prepareBluetoothDecoderAsynchronously()
        }

        let outputStatus = pcmOutput.start(
            deviceID: virtual.id,
            deviceUID: virtual.uid
        )
        guard outputStatus == noErr else {
            decoder = nil
            return .failed(message:
                "Could not open \(virtual.name) for Bluetooth mic audio (Core Audio \(outputStatus))."
            )
        }

        rememberDefaultInputBeforeBluetoothRoute()
        activeVirtualDeviceID = virtual.id
        prepareBluetoothMicrophonePlayout(decoder: newDecoder)

        let hidStatus = bluetoothHID.startMicrophoneStream()
        guard hidStatus == kIOReturnSuccess else {
            stopBluetoothMicrophonePlayout()
            pcmOutput.endSessionKeepingPrepared()
            activeVirtualDeviceID = nil
            savedDefaultInputID = nil
            return .failed(message: "Could not start controller Bluetooth audio (IOKit \(hidStatus)).")
        }

        let defaultStatus = setDefaultInputDevice(virtual.id)
        guard defaultStatus == noErr else {
            stopBluetoothMicrophone(restoreDefaultInput: false)
            return .failed(message: "Could not select \(virtual.name) (Core Audio \(defaultStatus)).")
        }

        bluetoothActivationCount = 1
        DiagnosticLog.write(
            "Bluetooth PS5 mic routed through \(virtual.name) (\(virtual.uid))"
        )
        return .activated(name: "DualSense BT Mic via \(virtual.name)")
    }

    /// Call after releasing the shortcut that owns the microphone. A short
    /// tail lets the receiving app consume the final decoded speech frames.
    func deactivate() {
        if usbMicrophoneActivationCount > 0 {
            usbMicrophoneActivationCount -= 1
            if usbMicrophoneActivationCount == 0 {
                endUSBMicrophoneIndicator()
            }
            return
        }

        guard bluetoothActivationCount > 0 else { return }
        bluetoothActivationCount -= 1
        guard bluetoothActivationCount == 0 else { return }

        bluetoothHID.showMicrophoneFinishedIndicator()
        pendingStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.stopBluetoothMicrophone(restoreDefaultInput: true)
        }
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// True while any microphone session owns the controller's lightbar and
    /// haptics: a live Bluetooth Opus stream, a held USB dictation shortcut,
    /// or the USB amber finished window (the Bluetooth amber is covered by
    /// the stream's own 0.8 s drain, so this keeps the transports
    /// symmetric). Distinct from `isBluetoothMicrophoneActive`, which gates
    /// raw-report input authority and must stay Bluetooth-specific.
    var isMicrophoneSessionActive: Bool {
        bluetoothHID.isMicrophoneStreaming
            || usbMicrophoneActivationCount > 0
            || pendingUSBSessionEnd != nil
    }

    /// Mirrors the Bluetooth session's lightbar choreography for the native
    /// USB microphone: blue while the shortcut holds the mic, an amber
    /// finished flash on release, then the shared session-ended callback so
    /// agent feedback can reclaim the LED. Capture itself is Core Audio's
    /// business over USB; only the indicators are ours.
    private func beginUSBMicrophoneIndicator() {
        pendingUSBSessionEnd?.cancel()
        pendingUSBSessionEnd = nil
        usbMicrophoneActivationCount += 1
        guard usbMicrophoneActivationCount == 1 else { return }

        // Agent haptic steps are suppressed while any microphone session is
        // active, so a pattern interrupted by this session start must have
        // its motors forced off now — the USB twin of the Bluetooth path's
        // pre-arming zero. The pattern may have been driving either
        // transport; zero both.
        usbHID.setRumble(lowFrequencyMotor: 0, highFrequencyMotor: 0)
        bluetoothHID.setAgentRumble(lowFrequencyMotor: 0, highFrequencyMotor: 0)
        usbHID.setLightbar(
            red: Self.recordingLightbar.red,
            green: Self.recordingLightbar.green,
            blue: Self.recordingLightbar.blue
        )
    }

    private func endUSBMicrophoneIndicator() {
        usbHID.setLightbar(
            red: Self.finishedLightbar.red,
            green: Self.finishedLightbar.green,
            blue: Self.finishedLightbar.blue
        )
        // Match the Bluetooth session's rhythm: the finished indicator holds
        // briefly before the shared callback lets agent state reclaim the
        // lightbar.
        pendingUSBSessionEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingUSBSessionEnd = nil
            self.onMicrophoneSessionEnded?()
        }
        pendingUSBSessionEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Decode each real controller packet exactly once. Advancing the CELT
    /// decoder through counter gaps, even while discarding PLC output, badly
    /// corrupts the following genuine frames on this controller stream.
    private func decode(_ frame: Data, counter: UInt8) {
        decodeQueue.async { [weak self] in
            guard let self,
                  self.bluetoothHID.isMicrophoneStreaming,
                  let decoder = self.decoder,
                  let samples = decoder.decode(frame) else {
                return
            }
            self.publishDecodedMicrophoneSamples(
                samples,
                counter: counter
            )
        }
    }

    private func prepareBluetoothMicrophonePlayout(
        decoder newDecoder: BluetoothOpusDecoder
    ) {
        decodeQueue.sync {
            decoder = newDecoder
            decodedFrameCount = 0
            decodedNonSilentFrameCount = 0
            decodedMaximumPeak = 0
            droppedMicrophonePacketCount = 0
        }
    }

    private func prewarmBluetoothDecoderSynchronously() {
        decoderPreparationLock.lock()
        guard preparedDecoder == nil,
              !decoderPreparationInFlight else {
            decoderPreparationLock.unlock()
            return
        }
        decoderPreparationInFlight = true
        decoderPreparationLock.unlock()

        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = Result { try BluetoothOpusDecoder() }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        decoderPreparationLock.lock()
        if case let .success(newDecoder) = result,
           preparedDecoder == nil {
            preparedDecoder = newDecoder
        }
        decoderPreparationInFlight = false
        decoderPreparationLock.unlock()

        switch result {
        case .success:
            DiagnosticLog.write(
                String(
                    format: "Bluetooth Opus decoder prepared during launch; elapsed=%.3fs",
                    elapsed
                )
            )
        case let .failure(error):
            DiagnosticLog.write(
                "Bluetooth Opus decoder launch preparation failed: \(error.localizedDescription)"
            )
        }
    }

    private func takePreparedBluetoothDecoder() -> BluetoothOpusDecoder? {
        decoderPreparationLock.lock()
        defer { decoderPreparationLock.unlock() }
        let readyDecoder = preparedDecoder
        preparedDecoder = nil
        return readyDecoder
    }

    private func prepareBluetoothDecoderAsynchronously() {
        decoderPreparationLock.lock()
        guard preparedDecoder == nil,
              !decoderPreparationInFlight else {
            decoderPreparationLock.unlock()
            return
        }
        decoderPreparationInFlight = true
        decoderPreparationLock.unlock()

        decoderPreparationQueue.async { [weak self] in
            let result = Result { try BluetoothOpusDecoder() }
            guard let self else { return }

            self.decoderPreparationLock.lock()
            if case let .success(newDecoder) = result,
               self.preparedDecoder == nil {
                self.preparedDecoder = newDecoder
            }
            self.decoderPreparationInFlight = false
            self.decoderPreparationLock.unlock()

            if case let .failure(error) = result {
                DiagnosticLog.write(
                    "Bluetooth Opus decoder background preparation failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func stopBluetoothMicrophonePlayout() {
        decodeQueue.sync {
            decoder = nil
        }
    }

    private func publishDecodedMicrophoneSamples(
        _ samples: [Int16],
        counter: UInt8
    ) {
        let peak = samples.lazy.map { abs(Int($0)) }.max() ?? 0
        decodedFrameCount += 1
        if peak > 0 {
            decodedNonSilentFrameCount += 1
        }
        if decodedFrameCount <= 10 || decodedFrameCount.isMultiple(of: 100) {
            DiagnosticLog.write(
                "Bluetooth microphone decoded real frame #\(decodedFrameCount), peak=\(peak)"
            )
        }
        decodedMaximumPeak = max(decodedMaximumPeak, peak)
        pcmOutput.enqueue(samples, counter: counter)
    }

    private func stopBluetoothMicrophone(restoreDefaultInput: Bool) {
        pendingStop?.cancel()
        pendingStop = nil
        bluetoothActivationCount = 0

        bluetoothHID.stopMicrophoneStream()
        stopBluetoothMicrophonePlayout()
        DiagnosticLog.write(
            "Bluetooth microphone audio summary: decoded=\(decodedFrameCount), nonSilent=\(decodedNonSilentFrameCount), decoderStateAdvances=0, jitterDrops=\(droppedMicrophonePacketCount), maximumPeak=\(decodedMaximumPeak)"
        )
        pcmOutput.endSessionKeepingPrepared()

        if restoreDefaultInput,
           let currentID = defaultInputDeviceID(),
           let current = audioDevice(id: currentID),
           current.uid == Self.bridgeDeviceUID,
           let previous = savedDefaultInputID.flatMap(audioDevice(id:))
                ?? rememberedOrPhysicalFallbackInput() {
            let status = setDefaultInputDevice(previous.id)
            if status == noErr {
                unmuteIfSupported(deviceID: previous.id)
                UserDefaults.standard.removeObject(
                    forKey: Self.previousDefaultInputUIDKey
                )
                DiagnosticLog.write(
                    "restored previous default input to \(previous.name)"
                )
            } else {
                DiagnosticLog.write(
                    "failed to restore previous default input \(previous.name): \(status)"
                )
            }
        }
        savedDefaultInputID = nil
        self.activeVirtualDeviceID = nil
        DiagnosticLog.write("Bluetooth PS5 mic audio route stopped")
        DispatchQueue.main.async { [weak self] in
            self?.onMicrophoneSessionEnded?()
        }
    }

    private func dualSenseUSBInputDevice() -> AudioDevice? {
        audioDevices().first { device in
            // The project-owned virtual device deliberately contains
            // "DualSense" in its display name. It must never be mistaken for
            // the physical USB microphone, or activation selects the empty
            // loopback input without ever starting Bluetooth HID capture.
            guard device.hasInput,
                  device.uid != Self.bridgeDeviceUID,
                  device.transportType != kAudioDeviceTransportTypeVirtual else {
                return false
            }
            let nameMatches = device.name.localizedCaseInsensitiveContains("dualsense")
                || device.name.localizedCaseInsensitiveContains("wireless controller")
            let manufacturerMatches = device.manufacturer.localizedCaseInsensitiveContains("sony")
                || device.manufacturer.localizedCaseInsensitiveContains("interactive entertainment")
            return nameMatches
                && (manufacturerMatches || device.transportType == kAudioDeviceTransportTypeUSB)
        }
    }

    /// Bluetooth audio is routed only through the driver shipped by this
    /// project. Never silently depend on a third-party cable that users of an
    /// open-source build may not have installed.
    private func supportedVirtualDevice() -> AudioDevice? {
        let candidates = audioDevices().filter { $0.hasInput && $0.hasOutput }
        return candidates.first {
            $0.name.localizedCaseInsensitiveContains("DualSense Bridge Mic")
                && $0.uid == Self.bridgeDeviceUID
        }
    }

    private func rememberDefaultInputBeforeBluetoothRoute() {
        let devices = audioDevices()
        let current = defaultInputDeviceID().flatMap { id in
            devices.first { $0.id == id }
        }
        let previous: AudioDevice?
        if let current,
           current.uid != Self.bridgeDeviceUID,
           current.transportType != kAudioDeviceTransportTypeVirtual {
            previous = current
        } else {
            previous = rememberedOrPhysicalFallbackInput(in: devices)
        }

        savedDefaultInputID = previous?.id
        if let previous {
            UserDefaults.standard.set(
                previous.uid,
                forKey: Self.previousDefaultInputUIDKey
            )
        }
    }

    private func audioDevice(id: AudioDeviceID) -> AudioDevice? {
        audioDevices().first { $0.id == id }
    }

    private func rememberedOrPhysicalFallbackInput(
        in devices: [AudioDevice]? = nil
    ) -> AudioDevice? {
        let devices = devices ?? audioDevices()
        if let rememberedUID = UserDefaults.standard.string(
            forKey: Self.previousDefaultInputUIDKey
        ),
        let remembered = devices.first(where: {
            $0.uid == rememberedUID
                && $0.hasInput
                && $0.uid != Self.bridgeDeviceUID
                && $0.transportType != kAudioDeviceTransportTypeVirtual
        }) {
            return remembered
        }

        let physicalInputs = devices.filter {
            $0.hasInput
                && $0.uid != Self.bridgeDeviceUID
                && $0.transportType != kAudioDeviceTransportTypeVirtual
        }
        return physicalInputs.first {
            $0.transportType == kAudioDeviceTransportTypeBuiltIn
                && $0.name.localizedCaseInsensitiveContains("microphone")
        } ?? physicalInputs.first {
            $0.transportType == kAudioDeviceTransportTypeBuiltIn
        } ?? physicalInputs.first
    }

    private func audioDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        let readStatus = deviceIDs.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        guard readStatus == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard let name = stringProperty(
                selector: kAudioObjectPropertyName,
                objectID: deviceID
            ),
            let uid = stringProperty(
                selector: kAudioDevicePropertyDeviceUID,
                objectID: deviceID
            ) else {
                return nil
            }
            return AudioDevice(
                id: deviceID,
                name: name,
                manufacturer: stringProperty(
                    selector: kAudioObjectPropertyManufacturer,
                    objectID: deviceID
                ) ?? "",
                uid: uid,
                transportType: uint32Property(
                    selector: kAudioDevicePropertyTransportType,
                    objectID: deviceID
                ) ?? 0,
                hasInput: hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput),
                hasOutput: hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
            )
        }
    }

    private func uint32Property(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private func hasStreams(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )
        return status == noErr && dataSize >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private func stringProperty(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr,
        let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr,
        deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
    }

    private func unmuteIfSupported(deviceID: AudioDeviceID) {
        for element in [
            kAudioObjectPropertyElementMain,
            AudioObjectPropertyElement(1),
            AudioObjectPropertyElement(2)
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }

            var isSettable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
                  isSettable.boolValue else {
                continue
            }

            var unmuted: UInt32 = 0
            _ = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &unmuted
            )
        }
    }
}
