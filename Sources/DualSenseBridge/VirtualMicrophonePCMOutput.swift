import AudioToolbox
import CoreAudio
import DualSenseBridgeCore
import Foundation

/// Sends decoded controller speech through a time-domain, speech-oriented
/// correction before it reaches the project-owned virtual microphone. The
/// controller produces 100 Opus frames/s but this Bluetooth link consistently
/// delivers about 44. Sonic restores the missing duration by overlapping full
/// pitch periods, avoiding both resampling pitch shift and phase-vocoder blur.
final class VirtualMicrophonePCMOutput {
    var onRenderedSamples: (([Int16]) -> Void)?

    private enum Backend {
        case none
        case speechCorrected
        case legacy
    }

    private let speechCorrected = SpeechCorrectedPCMOutput()
    private let legacy = AudioQueuePCMOutput(
        prebufferFrames: 2_400,
        resumeFrames: 480,
        smoothGaps: false
    )
    private var backend = Backend.none
    private var preparedDeviceUID: String?

    init() {
        speechCorrected.onRenderedSamples = { [weak self] samples in
            self?.onRenderedSamples?(samples)
        }
    }

    func start(deviceID: AudioDeviceID, deviceUID: String) -> OSStatus {
        if backend != .none, preparedDeviceUID == deviceUID {
            resetPreparedSession(reportGaps: false)
            DiagnosticLog.write(
                "reusing prepared virtual microphone AudioQueue; Core Audio startup delay=0ms"
            )
            return noErr
        }

        stop()

        let correctedStatus = speechCorrected.start(deviceUID: deviceUID)
        if correctedStatus == noErr {
            backend = .speechCorrected
            preparedDeviceUID = deviceUID
            DiagnosticLog.write(
                "virtual mic post-processing active: paired-reference cleanup=70Hz-5kHz with +3dB/180Hz shelf, Apache Sonic quality=1 pitch-period expansion with one fixed ratio per utterance and previous-session counter learning, finalTone=+2.5dB/180Hz shelf, initialBuffer=21600, underrunResume=7200, gain=0dB"
            )
            return noErr
        }

        DiagnosticLog.write(
            "time-domain speech output unavailable (Core Audio \(correctedStatus)); using understandable raw-frame fallback"
        )
        let legacyStatus = legacy.start(deviceUID: deviceUID)
        if legacyStatus == noErr {
            backend = .legacy
            preparedDeviceUID = deviceUID
        }
        return legacyStatus
    }

    /// Ends one controller-microphone session without tearing down the live
    /// AudioQueue. Keeping the queue primed removes the measured Core Audio
    /// open delay from the next Triangle/Square press, including the first
    /// press after launch.
    func endSessionKeepingPrepared() {
        resetPreparedSession(reportGaps: true)
    }

    func stop() {
        switch backend {
        case .speechCorrected:
            speechCorrected.stop()
        case .legacy:
            legacy.stop()
        case .none:
            speechCorrected.stop()
            legacy.stop()
        }
        backend = .none
        preparedDeviceUID = nil
    }

    func enqueue(_ samples: [Int16], counter: UInt8) {
        switch backend {
        case .speechCorrected:
            speechCorrected.enqueue(samples, counter: counter)
        case .legacy:
            legacy.enqueue(samples)
            onRenderedSamples?(samples)
        case .none:
            break
        }
    }

    private func resetPreparedSession(reportGaps: Bool) {
        switch backend {
        case .speechCorrected:
            speechCorrected.resetSession(reportGaps: reportGaps)
        case .legacy:
            legacy.resetForSession(reportGaps: reportGaps)
        case .none:
            break
        }
    }
}

private final class SpeechCorrectedPCMOutput {
    private static let defaultSessionTimeRatio = 2.30
    private static let minimumLearnedFrameCount =
        DualSenseAdaptiveSpeechTiming.calibrationFrameCount
    private static let savedTimeRatioKey =
        "local.controllerproject.DualSenseBridge.lastSpeechTimeRatio"

    var onRenderedSamples: (([Int16]) -> Void)?

    private var cleanupFilter = DualSenseSpeechCleanupFilter()
    // The broad 500 Hz dip selected for SOLA regressed Sonic's archived speech
    // recognition. Retain only the consistently useful body shelf.
    private var finishingFilter = DualSenseSpeechFinishingFilter(
        lowerMidGainDB: 0
    )
    private var adaptiveTiming = DualSenseAdaptiveSpeechTiming()
    private let stretcher: DualSenseSonicSpeechTimeStretcher
    private var sessionTimeRatio: Double
    private var nextSessionTimeRatio: Double
    private let output = AudioQueuePCMOutput(
        // The latest capture still exhausted the 300 ms reservoir once and
        // inserted a 125 ms discontinuity. A 450 ms initial reservoir covers
        // the measured startup convergence, retained SOLA tail and arrival
        // outlier together; a 150 ms resume threshold prevents a second
        // start-stop edge if radio delivery briefly stalls.
        prebufferFrames: 21_600,
        resumeFrames: 7_200,
        smoothGaps: true
    )

    init() {
        let savedRatio = UserDefaults.standard.double(
            forKey: Self.savedTimeRatioKey
        )
        let initialRatio = (2.0...2.6).contains(savedRatio)
            ? savedRatio
            : Self.defaultSessionTimeRatio
        sessionTimeRatio = initialRatio
        nextSessionTimeRatio = initialRatio
        stretcher = DualSenseSonicSpeechTimeStretcher(
            timeRatio: initialRatio,
            quality: 1
        )
        output.onRenderedSamples = { [weak self] samples in
            self?.onRenderedSamples?(samples)
        }
    }

    func start(deviceUID: String) -> OSStatus {
        stop()
        cleanupFilter.reset()
        finishingFilter.reset()
        stretcher.reset()
        beginTimingSession()
        return output.start(deviceUID: deviceUID)
    }

    func resetSession(reportGaps: Bool) {
        finishTimingSession()
        output.resetForSession(reportGaps: reportGaps)
        cleanupFilter.reset()
        finishingFilter.reset()
        stretcher.reset()
        adaptiveTiming.reset()
        beginTimingSession()
    }

    func stop() {
        finishTimingSession()
        output.stop()
        cleanupFilter.reset()
        finishingFilter.reset()
        stretcher.reset()
        adaptiveTiming.reset()
        beginTimingSession()
    }

    func enqueue(_ samples: [Int16], counter: UInt8) {
        _ = adaptiveTiming.observe(counter: counter)
        if adaptiveTiming.receivedFrameCount == 8
            || adaptiveTiming.receivedFrameCount.isMultiple(of: 100) {
            DiagnosticLog.write(
                String(
                    format: "virtual mic timing measurement: received=%d, generated=%d, measuredRatio=%.4f, fixedSessionRatio=%.4f",
                    adaptiveTiming.receivedFrameCount,
                    adaptiveTiming.generatedFrameCount,
                    adaptiveTiming.timeRatio,
                    sessionTimeRatio
                )
            )
        }
        let cleaned = cleanupFilter.process(samples)
        let stretched = stretcher.process(cleaned)
        if !stretched.isEmpty {
            output.enqueue(finishingFilter.process(stretched))
        }
    }

    private func beginTimingSession() {
        sessionTimeRatio = nextSessionTimeRatio
        stretcher.setTimeRatio(sessionTimeRatio)
        DiagnosticLog.write(
            String(
                format: "virtual mic Sonic session fixed ratio=%.4f",
                sessionTimeRatio
            )
        )
    }

    private func finishTimingSession() {
        guard adaptiveTiming.receivedFrameCount > 0 else { return }
        DiagnosticLog.write(
            String(
                format: "virtual mic final timing measurement: received=%d, generated=%d, measuredRatio=%.4f, appliedRatio=%.4f",
                adaptiveTiming.receivedFrameCount,
                adaptiveTiming.generatedFrameCount,
                adaptiveTiming.timeRatio,
                sessionTimeRatio
            )
        )
        guard adaptiveTiming.receivedFrameCount
                >= Self.minimumLearnedFrameCount else {
            return
        }
        let learnedRatio = min(max(adaptiveTiming.timeRatio, 2.0), 2.6)
        nextSessionTimeRatio = learnedRatio
        UserDefaults.standard.set(
            learnedRatio,
            forKey: Self.savedTimeRatioKey
        )
        DiagnosticLog.write(
            String(
                format: "virtual mic learned next fixed Sonic ratio=%.4f",
                learnedRatio
            )
        )
    }
}

/// Proven raw AudioQueue path retained as a fallback if the speech-processing
/// graph cannot open the virtual device on a future macOS release.
private final class AudioQueuePCMOutput {
    private static let sampleRate = 48_000.0
    private static let framesPerBuffer = 480
    private static let ringCapacity = 96_000

    var onRenderedSamples: (([Int16]) -> Void)?

    private let lock = NSLock()
    private let prebufferFrames: Int
    private let resumeFrames: Int
    private let smoothGaps: Bool
    private var ring = [Int16](repeating: 0, count: ringCapacity)
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0
    private var isReady = false
    private var hasStartedPlayback = false
    private var signalFrames = 0
    private var gapFrames = 0
    private var gapTransitions = 0
    private var lastRenderedHadSignal: Bool?
    private var gapSmoother = DualSensePCMGapSmoother()
    private var queue: AudioQueueRef?

    init(prebufferFrames: Int, resumeFrames: Int, smoothGaps: Bool) {
        self.prebufferFrames = max(prebufferFrames, Self.framesPerBuffer)
        self.resumeFrames = max(
            min(resumeFrames, self.prebufferFrames),
            Self.framesPerBuffer
        )
        self.smoothGaps = smoothGaps
    }

    func start(deviceUID: String) -> OSStatus {
        stop()

        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var newQueue: AudioQueueRef?
        var status = AudioQueueNewOutput(
            &format,
            virtualMicrophoneAudioQueueCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &newQueue
        )
        guard status == noErr, let newQueue else { return status }
        queue = newQueue

        let uid = deviceUID as CFString
        var uidReference = Unmanaged.passUnretained(uid)
        status = AudioQueueSetProperty(
            newQueue,
            kAudioQueueProperty_CurrentDevice,
            &uidReference,
            UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        )
        guard status == noErr else {
            stop()
            return status
        }

        resetRing()
        let bufferBytes = UInt32(Self.framesPerBuffer * MemoryLayout<Int16>.size)
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(newQueue, bufferBytes, &buffer)
            guard status == noErr, let buffer else {
                stop()
                return status
            }
            fill(buffer: buffer, queue: newQueue)
        }

        status = AudioQueueStart(newQueue, nil)
        if status != noErr {
            stop()
        }
        return status
    }

    func stop() {
        guard let queue else {
            resetRing()
            return
        }
        self.queue = nil
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        resetRing(reportGaps: true)
    }

    func resetForSession(reportGaps: Bool) {
        resetRing(reportGaps: reportGaps)
    }

    func enqueue(_ samples: [Int16]) {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            if availableFrames == Self.ringCapacity {
                readIndex = (readIndex + 1) % Self.ringCapacity
                availableFrames -= 1
            }
            ring[writeIndex] = sample
            writeIndex = (writeIndex + 1) % Self.ringCapacity
            availableFrames += 1
        }
    }

    fileprivate func fill(buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity) / MemoryLayout<Int16>.size
        let frameCount = min(capacity, Self.framesPerBuffer)
        let destination = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)

        lock.lock()
        let readinessThreshold = hasStartedPlayback
            ? resumeFrames
            : prebufferFrames
        if !isReady, availableFrames >= readinessThreshold {
            isReady = true
            hasStartedPlayback = true
        }
        var rendered = onRenderedSamples == nil
            ? []
            : [Int16](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let source: Int16?
            if isReady, availableFrames > 0 {
                source = ring[readIndex]
                readIndex = (readIndex + 1) % Self.ringCapacity
                availableFrames -= 1
            } else {
                source = nil
                if availableFrames == 0 {
                    isReady = false
                }
            }
            if hasStartedPlayback {
                let hasSignal = source != nil
                if hasSignal {
                    signalFrames += 1
                } else {
                    gapFrames += 1
                    if lastRenderedHadSignal == true {
                        gapTransitions += 1
                    }
                }
                lastRenderedHadSignal = hasSignal
            }
            let sample = smoothGaps
                ? gapSmoother.render(source)
                : (source ?? 0)
            destination[index] = sample
            if !rendered.isEmpty {
                rendered[index] = sample
            }
        }
        lock.unlock()

        buffer.pointee.mAudioDataByteSize = UInt32(frameCount * MemoryLayout<Int16>.size)
        _ = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if !rendered.isEmpty {
            onRenderedSamples?(rendered)
        }
    }

    private func resetRing(reportGaps: Bool = false) {
        lock.lock()
        let completedSignalFrames = signalFrames
        let completedGapFrames = gapFrames
        let completedGapTransitions = gapTransitions
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        isReady = false
        hasStartedPlayback = false
        signalFrames = 0
        gapFrames = 0
        gapTransitions = 0
        lastRenderedHadSignal = nil
        gapSmoother.reset()
        lock.unlock()

        let completedFrames = completedSignalFrames + completedGapFrames
        guard reportGaps, smoothGaps, completedFrames > 0 else { return }
        let signalDuty = 100.0 * Double(completedSignalFrames)
            / Double(completedFrames)
        let totalGapMilliseconds = Double(completedGapFrames)
            / (Self.sampleRate / 1_000.0)
        let averageGapMilliseconds = completedGapTransitions > 0
            ? totalGapMilliseconds / Double(completedGapTransitions)
            : totalGapMilliseconds
        DiagnosticLog.write(
            String(
                format: "virtual mic output continuity: signal=%d, gap=%d, duty=%.1f%%, underruns=%d, totalGap=%.1fms, averageGap=%.1fms",
                completedSignalFrames,
                completedGapFrames,
                signalDuty,
                completedGapTransitions,
                totalGapMilliseconds,
                averageGapMilliseconds
            )
        )
    }
}

private func virtualMicrophoneAudioQueueCallback(
    userData: UnsafeMutableRawPointer?,
    queue: AudioQueueRef,
    buffer: AudioQueueBufferRef
) {
    guard let userData else { return }
    Unmanaged<AudioQueuePCMOutput>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .fill(buffer: buffer, queue: queue)
}
