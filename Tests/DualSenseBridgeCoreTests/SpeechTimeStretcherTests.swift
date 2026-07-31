import Foundation
import Testing
@testable import DualSenseBridgeCore

@Test func speechTimeStretcherExpandsAudioWithoutLoweringItsPitch() {
    let sampleRate = 48_000.0
    let frequency = 220.0
    let inputCount = 48_000
    let input = (0..<inputCount).map { index -> Int16 in
        let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
        return Int16((sin(phase) * 12_000).rounded())
    }

    let stretcher = DualSenseSpeechTimeStretcher(timeRatio: 2.38)
    var output: [Int16] = []
    for start in stride(from: 0, to: input.count, by: 480) {
        output.append(contentsOf: stretcher.process(
            Array(input[start..<min(start + 480, input.count)])
        ))
    }

    // The unflushed analysis tail is intentionally small, so a one-second
    // stream should remain close to the requested 2.38x expansion.
    let measuredRatio = Double(output.count) / Double(input.count)
    #expect(measuredRatio > 2.30)
    #expect(measuredRatio < 2.40)

    // Count rising zero crossings away from the startup edge. Time-domain
    // overlap-add must retain the original voice pitch rather than producing
    // the deep voice caused by naive resampling.
    let analysisStart = min(4_800, output.count)
    var risingCrossings = 0
    if analysisStart + 1 < output.count {
        for index in (analysisStart + 1)..<output.count {
            if output[index - 1] < 0, output[index] >= 0 {
                risingCrossings += 1
            }
        }
    }
    let analyzedDuration = Double(output.count - analysisStart) / sampleRate
    let measuredFrequency = Double(risingCrossings) / analyzedDuration
    #expect(measuredFrequency > 205)
    #expect(measuredFrequency < 235)
}

@Test func speechTimeStretcherResetDropsBufferedAudio() {
    let stretcher = DualSenseSpeechTimeStretcher()
    let frame = [Int16](repeating: 1_000, count: 480)
    for _ in 0..<8 {
        _ = stretcher.process(frame)
    }
    stretcher.reset()

    #expect(stretcher.process(frame).isEmpty)
    #expect(stretcher.process(frame).isEmpty)
    let restartedOutput = stretcher.process(frame)
    #expect(restartedOutput.count == 720)
    #expect(restartedOutput.allSatisfy { $0 == 1_000 })
}

@Test func speechTimeStretcherCanAdjustExpansionWithoutResettingSpeech() {
    let stretcher = DualSenseSpeechTimeStretcher(timeRatio: 2.32)
    let frame = [Int16](repeating: 1_000, count: 480)
    var output: [Int16] = []

    for _ in 0..<50 {
        output.append(contentsOf: stretcher.process(frame))
    }
    let beforeAdjustment = output.count
    stretcher.setTimeRatio(1.50)
    for _ in 0..<50 {
        output.append(contentsOf: stretcher.process(frame))
    }

    let firstHalfRatio = Double(beforeAdjustment) / Double(50 * frame.count)
    let secondHalfRatio = Double(output.count - beforeAdjustment)
        / Double(50 * frame.count)
    #expect(firstHalfRatio > 2.15)
    #expect(secondHalfRatio > 1.40)
    #expect(secondHalfRatio < 1.65)
    #expect(output.allSatisfy { $0 == 1_000 })
}

@Test func speechTimeStretcherUsesExplicitValidatedConfiguration() {
    let configuration = DualSenseSpeechTimeStretcher.Configuration(
        sequenceFrames: 960,
        synthesisHopFrames: 480,
        searchRadiusFrames: 48,
        alignmentLowPassCutoff: 700,
        alignmentPenalty: 0.03
    )
    let stretcher = DualSenseSpeechTimeStretcher(
        timeRatio: 2.0,
        configuration: configuration
    )
    let frame = [Int16](repeating: 750, count: 480)

    #expect(stretcher.process(frame).isEmpty)
    let firstOutput = stretcher.process(frame)

    #expect(firstOutput.count == 480)
    #expect(firstOutput.allSatisfy { $0 == 750 })
}

@Test func speechTimeStretcherDefaultsToValidatedPitchSynchronousAlignment() {
    let sampleRate = 48_000.0
    let input = (0..<24_000).map { index -> Int16 in
        let seconds = Double(index) / sampleRate
        let frequency = 118.0 + 18.0 * seconds
        let phase = 2 * Double.pi * frequency * seconds
        return Int16((sin(phase) * 10_000).rounded())
    }
    let automatic = DualSenseSpeechTimeStretcher(timeRatio: 2.32)
    let explicit = DualSenseSpeechTimeStretcher(
        timeRatio: 2.32,
        configuration: .init(
            sequenceFrames: 1_440,
            synthesisHopFrames: 720,
            searchRadiusFrames: 48,
            alignmentLowPassCutoff: 500,
            alignmentPenalty: 0.03,
            voicedSearchRadiusFrames: 160,
            voicingThreshold: 0.66
        )
    )
    let narrow = DualSenseSpeechTimeStretcher(
        timeRatio: 2.32,
        configuration: .init(
            alignmentPenalty: 0.03,
            voicedSearchRadiusFrames: nil,
            voicingThreshold: 0.66
        )
    )
    var automaticOutput: [Int16] = []
    var explicitOutput: [Int16] = []
    var narrowOutput: [Int16] = []
    for start in stride(from: 0, to: input.count, by: 480) {
        let frame = Array(input[start..<min(start + 480, input.count)])
        automaticOutput.append(contentsOf: automatic.process(frame))
        explicitOutput.append(contentsOf: explicit.process(frame))
        narrowOutput.append(contentsOf: narrow.process(frame))
    }

    #expect(automaticOutput == explicitOutput)
    #expect(automaticOutput != narrowOutput)
}

@Test func speechTimeStretcherKeepsNarrowSearchForUnvoicedSignal() {
    var state: UInt32 = 0x1234_5678
    let input = (0..<12_000).map { _ -> Int16 in
        state = state &* 1_664_525 &+ 1_013_904_223
        return Int16(truncatingIfNeeded: state >> 17)
    }
    let pitchSynchronous = DualSenseSpeechTimeStretcher(timeRatio: 2.32)
    let narrow = DualSenseSpeechTimeStretcher(
        timeRatio: 2.32,
        configuration: .init(
            alignmentPenalty: 0.03,
            voicedSearchRadiusFrames: nil,
            voicingThreshold: 0.66
        )
    )
    var pitchSynchronousOutput: [Int16] = []
    var narrowOutput: [Int16] = []
    for start in stride(from: 0, to: input.count, by: 480) {
        let frame = Array(input[start..<min(start + 480, input.count)])
        pitchSynchronousOutput.append(
            contentsOf: pitchSynchronous.process(frame)
        )
        narrowOutput.append(contentsOf: narrow.process(frame))
    }

    #expect(pitchSynchronousOutput == narrowOutput)
}
