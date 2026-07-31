import Foundation
import Testing
@testable import DualSenseBridgeCore

@Test func speechCleanupPreservesVoiceAndRejectsBroadbandDistortion() {
    let sampleRate = 48_000.0
    let sampleCount = 48_000
    let voiceFrequency = 500.0
    let distortionFrequency = 8_000.0

    var voiceFilter = DualSenseSpeechCleanupFilter()
    var distortionFilter = DualSenseSpeechCleanupFilter()
    let voice = (0..<sampleCount).map { index -> Int16 in
        let phase = 2 * Double.pi * voiceFrequency * Double(index) / sampleRate
        return Int16((sin(phase) * 10_000).rounded())
    }
    let distortion = (0..<sampleCount).map { index -> Int16 in
        let phase = 2 * Double.pi * distortionFrequency * Double(index) / sampleRate
        return Int16((sin(phase) * 10_000).rounded())
    }

    let filteredVoice = voiceFilter.process(voice)
    let filteredDistortion = distortionFilter.process(distortion)
    let analysisStart = 4_800
    let voiceRMS = rms(Array(filteredVoice[analysisStart...]))
    let distortionRMS = rms(Array(filteredDistortion[analysisStart...]))

    #expect(voiceRMS > 6_000)
    // The cross-recording 5 kHz setting deliberately retains more consonant
    // detail than the former 4 kHz edge while still rejecting almost 90% of
    // an 8 kHz discontinuity tone.
    #expect(distortionRMS < 800)
    #expect(distortionRMS < voiceRMS * 0.11)
}

@Test func speechCleanupResetRestoresInitialState() {
    var filter = DualSenseSpeechCleanupFilter()
    let impulse: [Int16] = [10_000] + [Int16](repeating: 0, count: 100)
    let first = filter.process(impulse)
    _ = filter.process([Int16](repeating: 2_000, count: 1_000))
    filter.reset()
    let afterReset = filter.process(impulse)

    #expect(first == afterReset)
}

@Test func speechCleanupRestoresVoiceBodyWithoutBoostingPresence() {
    let sampleRate = 48_000.0
    let sampleCount = 96_000

    func filteredRMS(frequency: Double, shelfGainDB: Double) -> Double {
        var filter = DualSenseSpeechCleanupFilter(
            lowShelfGainDB: shelfGainDB
        )
        let input = (0..<sampleCount).map { index -> Int16 in
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            return Int16((sin(phase) * 8_000).rounded())
        }
        let output = filter.process(input)
        return rms(Array(output[48_000...]))
    }

    let lowNeutral = filteredRMS(frequency: 120, shelfGainDB: 0)
    let lowRestored = filteredRMS(frequency: 120, shelfGainDB: 3)
    let presenceNeutral = filteredRMS(frequency: 1_000, shelfGainDB: 0)
    let presenceRestored = filteredRMS(frequency: 1_000, shelfGainDB: 3)

    #expect(lowRestored > lowNeutral * 1.20)
    #expect(lowRestored < lowNeutral * 1.50)
    #expect(abs(presenceRestored / presenceNeutral - 1) < 0.02)
}

@Test func speechFinishingFilterRestoresBodyAndSoftensLowerMids() {
    let sampleRate = 48_000.0
    let sampleCount = 96_000

    func filteredRMS(
        frequency: Double,
        bodyGainDB: Double,
        lowerMidGainDB: Double
    ) -> Double {
        var filter = DualSenseSpeechFinishingFilter(
            bodyShelfGainDB: bodyGainDB,
            lowerMidGainDB: lowerMidGainDB
        )
        let input = (0..<sampleCount).map { index -> Int16 in
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            return Int16((sin(phase) * 8_000).rounded())
        }
        return rms(Array(filter.process(input)[48_000...]))
    }

    let neutral120 = filteredRMS(
        frequency: 120,
        bodyGainDB: 0,
        lowerMidGainDB: 0
    )
    let finished120 = filteredRMS(
        frequency: 120,
        bodyGainDB: 4.5,
        lowerMidGainDB: -1.5
    )
    let neutral420 = filteredRMS(
        frequency: 420,
        bodyGainDB: 0,
        lowerMidGainDB: 0
    )
    let finished420 = filteredRMS(
        frequency: 420,
        bodyGainDB: 4.5,
        lowerMidGainDB: -1.5
    )
    let neutral1K = filteredRMS(
        frequency: 1_000,
        bodyGainDB: 0,
        lowerMidGainDB: 0
    )
    let finished1K = filteredRMS(
        frequency: 1_000,
        bodyGainDB: 4.5,
        lowerMidGainDB: -1.5
    )

    #expect(finished120 > neutral120 * 1.35)
    #expect(finished420 < neutral420 * 0.95)
    #expect(abs(finished1K / neutral1K - 1) < 0.06)
}

@Test func speechFinishingFilterResetRestoresInitialState() {
    var filter = DualSenseSpeechFinishingFilter()
    let impulse: [Int16] = [10_000] + [Int16](repeating: 0, count: 100)
    let first = filter.process(impulse)
    _ = filter.process([Int16](repeating: 2_000, count: 1_000))
    filter.reset()
    let afterReset = filter.process(impulse)

    #expect(first == afterReset)
}

private func rms(_ samples: [Int16]) -> Double {
    let energy = samples.reduce(0.0) { partial, sample in
        partial + Double(sample) * Double(sample)
    }
    return sqrt(energy / Double(max(samples.count, 1)))
}
