import Foundation
import Testing
@testable import DualSenseBridgeCore

@Test func sonicSpeechTimeStretcherExpandsSpeechWithoutLoweringPitch() {
    let sampleRate = 48_000.0
    let frequency = 220.0
    let input = (0..<48_000).map { index -> Int16 in
        let phase = 2.0 * Double.pi * frequency * Double(index) / sampleRate
        return Int16((sin(phase) * 12_000).rounded())
    }
    let stretcher = DualSenseSonicSpeechTimeStretcher(
        timeRatio: 2.30,
        quality: 1
    )
    var output: [Int16] = []
    for start in stride(from: 0, to: input.count, by: 480) {
        output.append(contentsOf: stretcher.process(
            Array(input[start..<min(start + 480, input.count)])
        ))
    }
    output.append(contentsOf: stretcher.flush())

    let measuredRatio = Double(output.count) / Double(input.count)
    #expect(measuredRatio > 2.25)
    #expect(measuredRatio < 2.35)

    let analysisStart = min(4_800, output.count)
    var risingCrossings = 0
    if analysisStart + 1 < output.count {
        for index in (analysisStart + 1)..<output.count {
            if output[index - 1] < 0, output[index] >= 0 {
                risingCrossings += 1
            }
        }
    }
    let duration = Double(output.count - analysisStart) / sampleRate
    let measuredFrequency = Double(risingCrossings) / duration
    #expect(measuredFrequency > 210)
    #expect(measuredFrequency < 230)
}

@Test func sonicSpeechTimeStretcherResetIsDeterministic() {
    let input = (0..<24_000).map { index -> Int16 in
        let phase = 2.0 * Double.pi * 137.0 * Double(index) / 48_000.0
        return Int16((sin(phase) * 9_000).rounded())
    }
    let stretcher = DualSenseSonicSpeechTimeStretcher(timeRatio: 2.30)

    func render() -> [Int16] {
        var output: [Int16] = []
        for start in stride(from: 0, to: input.count, by: 480) {
            output.append(contentsOf: stretcher.process(
                Array(input[start..<min(start + 480, input.count)])
            ))
        }
        output.append(contentsOf: stretcher.flush())
        return output
    }

    let first = render()
    stretcher.reset()
    let second = render()

    #expect(!first.isEmpty)
    #expect(first == second)
}

@Test func sonicSpeechTimeStretcherUsesValidatedFixedRatio() {
    let stretcher = DualSenseSonicSpeechTimeStretcher(timeRatio: .infinity)
    #expect(stretcher.timeRatio == 2.30)

    stretcher.setTimeRatio(2.41)
    #expect(abs(stretcher.timeRatio - 2.41) < 0.000_001)

    stretcher.setTimeRatio(10)
    #expect(stretcher.timeRatio == 4.0)
}
