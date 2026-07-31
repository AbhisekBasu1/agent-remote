import Testing
@testable import DualSenseBridgeCore

@Test func adaptiveSpeechTimingUsesStartupPriorThenCounterRatio() {
    var timing = DualSenseAdaptiveSpeechTiming()
    let calibrationCount = DualSenseAdaptiveSpeechTiming.calibrationFrameCount
    let counters = (0..<(calibrationCount - 1)).map(UInt8.init)
        + [UInt8(calibrationCount)]

    for counter in counters.dropLast() {
        #expect(
            timing.observe(counter: counter)
                == DualSenseAdaptiveSpeechTiming.startupTimeRatio
        )
    }
    let ratio = timing.observe(counter: counters.last!)

    #expect(
        timing.receivedFrameCount
            == DualSenseAdaptiveSpeechTiming.calibrationFrameCount
    )
    #expect(timing.generatedFrameCount == calibrationCount + 1)
    #expect(
        abs(
            ratio
                - Double(calibrationCount + 1) / Double(calibrationCount)
        ) < 0.000_001
    )
}

@Test func adaptiveSpeechTimingHandlesWrapAndCanConvergeToNoLoss() {
    var timing = DualSenseAdaptiveSpeechTiming()
    let counters = (0..<DualSenseAdaptiveSpeechTiming.calibrationFrameCount)
        .map { UInt8((252 + $0) % 256) }
    for counter in counters {
        _ = timing.observe(counter: counter)
    }

    #expect(
        timing.generatedFrameCount
            == DualSenseAdaptiveSpeechTiming.calibrationFrameCount
    )
    #expect(timing.timeRatio == 1.0)
}

@Test func adaptiveSpeechTimingIgnoresDuplicateAndBackwardJumps() {
    var timing = DualSenseAdaptiveSpeechTiming()
    let counters: [UInt8] = [10, 11, 11, 10, 11, 12, 13, 14]
    for counter in counters {
        _ = timing.observe(counter: counter)
    }

    #expect(timing.generatedFrameCount == 8)
    #expect(
        timing.timeRatio == DualSenseAdaptiveSpeechTiming.startupTimeRatio
    )

    timing.reset()
    #expect(timing.receivedFrameCount == 0)
    #expect(timing.generatedFrameCount == 0)
    #expect(
        timing.timeRatio == DualSenseAdaptiveSpeechTiming.startupTimeRatio
    )
}
