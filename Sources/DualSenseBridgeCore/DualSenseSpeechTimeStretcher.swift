import Foundation

/// A small streaming, speech-oriented time stretcher based on synchronized
/// overlap-add (SOLA) with voiced, pitch-synchronous alignment. Unlike a
/// phase-vocoder effect, it never splits speech into spectral bins: it finds
/// a nearby waveform-aligned segment, crossfades the overlap, and preserves
/// the original pitch and formants in the time domain.
///
/// This type is deliberately self-contained so DualSense Bridge does not gain
/// a runtime audio dependency or a licence incompatible with the MIT project.
public final class DualSenseSpeechTimeStretcher {
    public struct Configuration: Sendable {
        public let sequenceFrames: Int
        public let synthesisHopFrames: Int
        public let searchRadiusFrames: Int
        public let alignmentLowPassCutoff: Double
        public let alignmentPenalty: Double
        public let voicedSearchRadiusFrames: Int?
        public let voicingThreshold: Double

        fileprivate var overlapFrames: Int {
            sequenceFrames - synthesisHopFrames
        }

        public init(
            sequenceFrames: Int = 1_440,
            synthesisHopFrames: Int = 720,
            searchRadiusFrames: Int = 48,
            alignmentLowPassCutoff: Double = 500,
            alignmentPenalty: Double = 0.03,
            voicedSearchRadiusFrames: Int? = 160,
            voicingThreshold: Double = 0.66
        ) {
            let safeSequence = max(sequenceFrames, 2)
            self.sequenceFrames = safeSequence
            self.synthesisHopFrames = min(
                max(synthesisHopFrames, 1),
                safeSequence - 1
            )
            let safeSearchRadius = max(searchRadiusFrames, 1)
            self.searchRadiusFrames = safeSearchRadius
            self.alignmentLowPassCutoff = min(
                max(alignmentLowPassCutoff, 80),
                20_000
            )
            self.alignmentPenalty = max(alignmentPenalty, 0)
            self.voicedSearchRadiusFrames = voicedSearchRadiusFrames.map {
                max($0, safeSearchRadius)
            }
            self.voicingThreshold = min(max(voicingThreshold, 0), 1)
        }
    }

    // Checking every sample avoids the phase mismatch at overlap boundaries
    // that gave sparse Bluetooth speech a metallic coloration. This remains
    // comfortably below one audio core's budget at the controller's cadence.
    private static let correlationStride = 1
    private static let pruneThresholdFrames = 8_192

    private let configuration: Configuration
    private var timeRatio: Double
    private let fadeIn: [Float]
    private var input: [Float] = []
    private var alignmentInput: [Float] = []
    private var previousTail: [Float]?
    private var previousAlignmentTail: [Float]?
    private var previousAlignmentContext: [Float]?
    private var nominalAnalysisPosition = 0.0
    private var lastSelectedPosition = 0
    private var alignmentHighPass: AlignmentBiquad
    private var alignmentLowPass: AlignmentBiquad

    /// `timeRatio` is output duration divided by compacted input duration.
    /// It may be updated as the controller counter reveals the current
    /// Bluetooth session's actual delivery ratio.
    public init(
        timeRatio: Double = 5.0 / 3.0,
        configuration: Configuration = Configuration()
    ) {
        self.configuration = configuration
        self.timeRatio = max(1.0, timeRatio)
        alignmentHighPass = AlignmentBiquad.highPass(
            sampleRate: 48_000,
            cutoff: 70
        )
        alignmentLowPass = AlignmentBiquad.lowPass(
            sampleRate: 48_000,
            cutoff: configuration.alignmentLowPassCutoff
        )
        fadeIn = (0..<configuration.overlapFrames).map { index in
            let phase = Double(index + 1)
                / Double(configuration.overlapFrames + 1)
            return Float(0.5 - 0.5 * cos(.pi * phase))
        }
        input.reserveCapacity(Self.pruneThresholdFrames * 2)
        alignmentInput.reserveCapacity(Self.pruneThresholdFrames * 2)
    }

    public func reset() {
        input.removeAll(keepingCapacity: true)
        alignmentInput.removeAll(keepingCapacity: true)
        previousTail = nil
        previousAlignmentTail = nil
        previousAlignmentContext = nil
        nominalAnalysisPosition = 0
        lastSelectedPosition = 0
        alignmentHighPass.reset()
        alignmentLowPass.reset()
    }

    /// Changes the expansion applied to audio produced after this call. The
    /// nominal analysis cursor remains continuous, so a gradually converging
    /// counter estimate does not reset or cut the speech waveform.
    public func setTimeRatio(_ timeRatio: Double) {
        self.timeRatio = min(max(timeRatio, 1.0), 4.0)
    }

    /// Appends decoded 48 kHz mono PCM and returns any newly stretched PCM.
    /// Calling this from one serial audio/decode queue is required.
    public func process(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        let analysisHopFrames = Double(configuration.synthesisHopFrames)
            / timeRatio
        let normalized = samples.map { Float($0) / 32_768.0 }
        input.append(contentsOf: normalized)
        for sample in normalized {
            let highPassed = alignmentHighPass.process(sample)
            alignmentInput.append(alignmentLowPass.process(highPassed))
        }

        var output: [Int16] = []
        if previousTail == nil {
            guard input.count >= configuration.sequenceFrames else { return [] }
            output.reserveCapacity(configuration.synthesisHopFrames * 2)
            appendPCM(
                input[0..<configuration.synthesisHopFrames],
                to: &output
            )
            previousTail = Array(
                input[configuration.synthesisHopFrames..<configuration.sequenceFrames]
            )
            previousAlignmentTail = Array(
                alignmentInput[configuration.synthesisHopFrames..<configuration.sequenceFrames]
            )
            previousAlignmentContext = Array(
                alignmentInput[0..<configuration.sequenceFrames]
            )
            nominalAnalysisPosition = analysisHopFrames
            lastSelectedPosition = 0
        }

        while let previousTail,
              let previousAlignmentTail,
              let previousAlignmentContext {
            let nominal = Int(nominalAnalysisPosition.rounded())
            let searchRadius = effectiveSearchRadius(
                reference: previousAlignmentContext
            )
            let earliest = max(
                0,
                max(
                    nominal - searchRadius,
                    lastSelectedPosition + 1
                )
            )
            let latest = nominal + searchRadius
            guard latest + configuration.sequenceFrames <= input.count,
                  earliest <= latest else {
                break
            }

            let selected = bestAlignedPosition(
                reference: previousAlignmentTail,
                range: earliest...latest,
                fallback: nominal,
                searchRadius: searchRadius
            )
            output.reserveCapacity(
                output.count + configuration.synthesisHopFrames
            )

            for index in 0..<configuration.overlapFrames {
                let incoming = input[selected + index]
                let weight = fadeIn[index]
                appendPCM(
                    previousTail[index] * (1 - weight) + incoming * weight,
                    to: &output
                )
            }
            appendPCM(
                input[(selected + configuration.overlapFrames)..<(selected + configuration.synthesisHopFrames)],
                to: &output
            )
            self.previousTail = Array(
                input[(selected + configuration.synthesisHopFrames)..<(selected + configuration.sequenceFrames)]
            )
            self.previousAlignmentTail = Array(
                alignmentInput[(selected + configuration.synthesisHopFrames)..<(selected + configuration.sequenceFrames)]
            )
            self.previousAlignmentContext = Array(
                alignmentInput[selected..<(selected + configuration.sequenceFrames)]
            )
            lastSelectedPosition = selected
            nominalAnalysisPosition += analysisHopFrames

            pruneInputIfNeeded()
        }
        return output
    }

    private func bestAlignedPosition(
        reference: [Float],
        range: ClosedRange<Int>,
        fallback: Int,
        searchRadius: Int
    ) -> Int {
        var referenceEnergy = 0.0
        var index = 0
        while index < configuration.overlapFrames {
            let value = Double(reference[index])
            referenceEnergy += value * value
            index += Self.correlationStride
        }
        guard referenceEnergy > 1e-8 else {
            return min(max(fallback, range.lowerBound), range.upperBound)
        }

        var bestPosition = min(max(fallback, range.lowerBound), range.upperBound)
        var bestScore = -Double.infinity
        for candidate in range {
            var dot = 0.0
            var candidateEnergy = 0.0
            var offset = 0
            while offset < configuration.overlapFrames {
                let incoming = Double(alignmentInput[candidate + offset])
                dot += Double(reference[offset]) * incoming
                candidateEnergy += incoming * incoming
                offset += Self.correlationStride
            }
            guard candidateEnergy > 1e-8 else { continue }
            let normalizedOffset = Double(candidate - fallback)
                / Double(max(searchRadius, 1))
            let score = dot / sqrt(referenceEnergy * candidateEnergy)
                - configuration.alignmentPenalty
                    * normalizedOffset * normalizedOffset
            if score > bestScore {
                bestScore = score
                bestPosition = candidate
            }
        }
        return bestPosition
    }

    /// Voiced speech needs a wider search than consonants: the two overlap
    /// windows can be almost half a pitch cycle out of phase. Detect a stable
    /// low-frequency period and widen only those alignments far enough to
    /// reach the matching phase. Keeping the original narrow radius for
    /// unvoiced speech avoids repeating or smearing short consonants.
    private func effectiveSearchRadius(reference: [Float]) -> Int {
        guard let maximumRadius = configuration.voicedSearchRadiusFrames,
              let estimate = pitchEstimate(reference: reference),
              estimate.periodicity >= configuration.voicingThreshold else {
            return configuration.searchRadiusFrames
        }
        let halfPeriodWithMargin = estimate.periodFrames / 2 + 12
        return min(
            maximumRadius,
            max(configuration.searchRadiusFrames, halfPeriodWithMargin)
        )
    }

    private func pitchEstimate(
        reference: [Float]
    ) -> (periodFrames: Int, periodicity: Double)? {
        // 80...400 Hz at 48 kHz. Require at least 240 paired samples so an
        // isolated edge cannot masquerade as a stable pitch period.
        let minimumLag = 120
        let maximumLag = min(600, reference.count - 240)
        guard maximumLag >= minimumLag else { return nil }

        var bestLag = minimumLag
        var bestScore = -Double.infinity
        for lag in minimumLag...maximumLag {
            var dot = 0.0
            var leftEnergy = 0.0
            var rightEnergy = 0.0
            var index = 0
            while index < reference.count - lag {
                let left = Double(reference[index])
                let right = Double(reference[index + lag])
                dot += left * right
                leftEnergy += left * left
                rightEnergy += right * right
                index += 2
            }
            guard leftEnergy > 1e-9, rightEnergy > 1e-9 else { continue }
            let score = dot / sqrt(leftEnergy * rightEnergy)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestScore.isFinite else { return nil }
        return (bestLag, bestScore)
    }

    private func pruneInputIfNeeded() {
        // Retain the conservative radius at each periodic prune. This gives
        // the source cursor a forward anchor instead of letting a long voiced
        // section stay locked to the same repeated pitch grain indefinitely.
        let removable = Int(nominalAnalysisPosition)
            - configuration.searchRadiusFrames
        guard removable >= Self.pruneThresholdFrames else { return }

        input.removeFirst(removable)
        alignmentInput.removeFirst(removable)
        nominalAnalysisPosition -= Double(removable)
        lastSelectedPosition -= removable
    }

    private func appendPCM(
        _ values: ArraySlice<Float>,
        to output: inout [Int16]
    ) {
        for value in values {
            appendPCM(value, to: &output)
        }
    }

    private func appendPCM(_ value: Float, to output: inout [Int16]) {
        let scaled = Int((value * 32_768.0).rounded())
        output.append(Int16(clamping: scaled))
    }
}

/// Minimal RBJ biquad used only to derive the low-frequency alignment guide.
/// The audible waveform remains in the existing project-owned cleanup path.
private struct AlignmentBiquad {
    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float
    private var input1: Float = 0
    private var input2: Float = 0
    private var output1: Float = 0
    private var output2: Float = 0

    static func lowPass(sampleRate: Double, cutoff: Double) -> Self {
        coefficients(sampleRate: sampleRate, cutoff: cutoff, highPass: false)
    }

    static func highPass(sampleRate: Double, cutoff: Double) -> Self {
        coefficients(sampleRate: sampleRate, cutoff: cutoff, highPass: true)
    }

    private static func coefficients(
        sampleRate: Double,
        cutoff: Double,
        highPass: Bool
    ) -> Self {
        let omega = 2.0 * Double.pi * cutoff / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2.0 * (1.0 / sqrt(2.0)))
        let a0 = 1.0 + alpha
        let numerator = highPass ? 1.0 + cosine : 1.0 - cosine
        let sign = highPass ? -1.0 : 1.0
        return Self(
            b0: Float(numerator * 0.5 / a0),
            b1: Float(sign * numerator / a0),
            b2: Float(numerator * 0.5 / a0),
            a1: Float(-2.0 * cosine / a0),
            a2: Float((1.0 - alpha) / a0)
        )
    }

    mutating func reset() {
        input1 = 0
        input2 = 0
        output1 = 0
        output2 = 0
    }

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input
            + b1 * input1
            + b2 * input2
            - a1 * output1
            - a2 * output2
        input2 = input1
        input1 = input
        output2 = output1
        output1 = output
        return output
    }
}
