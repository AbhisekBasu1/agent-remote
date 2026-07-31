import Foundation

/// Removes the out-of-band discontinuity energy present in the sparse
/// Bluetooth microphone frames before waveform alignment and time expansion.
/// Cross-recording replay showed that a 5 kHz edge retains more consonant
/// detail than the former 4 kHz setting without reopening the controller's
/// strongest discontinuity noise. This project-owned IIR cascade adds no
/// dependency or spectral/phase-vocoder processing.
public struct DualSenseSpeechCleanupFilter: Sendable {
    private var highPass: Biquad
    private var lowShelf: Biquad
    private var lowPass1: Biquad
    private var lowPass2: Biquad

    public init(
        sampleRate: Double = 48_000,
        highPassCutoff: Double = 70,
        lowShelfFrequency: Double = 180,
        lowShelfGainDB: Double = 3,
        lowPassCutoff: Double = 5_000
    ) {
        highPass = Biquad.highPass(
            sampleRate: sampleRate,
            cutoff: highPassCutoff
        )
        // Seven paired MacBook/controller references consistently showed the
        // reconstructed Bluetooth voice short of energy below 180 Hz. A very
        // gentle shelf restores body without boosting sub-70 Hz handling
        // rumble or reshaping the already-fragile speech harmonics.
        lowShelf = Biquad.lowShelf(
            sampleRate: sampleRate,
            frequency: lowShelfFrequency,
            gainDB: lowShelfGainDB
        )
        lowPass1 = Biquad.lowPass(
            sampleRate: sampleRate,
            cutoff: lowPassCutoff
        )
        lowPass2 = Biquad.lowPass(
            sampleRate: sampleRate,
            cutoff: lowPassCutoff
        )
    }

    public mutating func reset() {
        highPass.reset()
        lowShelf.reset()
        lowPass1.reset()
        lowPass2.reset()
    }

    public mutating func process(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        var output: [Int16] = []
        output.reserveCapacity(samples.count)
        for sample in samples {
            var value = highPass.process(Double(sample))
            value = lowShelf.process(value)
            value = lowPass1.process(value)
            value = lowPass2.process(value)
            output.append(Int16(clamping: Int(value.rounded())))
        }
        return output
    }
}

/// Applies the small, paired-reference tonal correction selected after SOLA.
/// Keeping this stage after waveform alignment means it cannot influence which
/// source segment SOLA chooses. Four paired captures retained a moderate body
/// shelf and consistently benefited from a broad 500 Hz dip, reducing the
/// controller's boxy lower-mid coloration without removing consonant energy.
public struct DualSenseSpeechFinishingFilter: Sendable {
    private var bodyShelf: Biquad
    private var lowerMidDip: Biquad

    public init(
        sampleRate: Double = 48_000,
        bodyShelfFrequency: Double = 180,
        bodyShelfGainDB: Double = 2.5,
        lowerMidFrequency: Double = 500,
        lowerMidGainDB: Double = -2,
        lowerMidQ: Double = 1.0
    ) {
        bodyShelf = Biquad.lowShelf(
            sampleRate: sampleRate,
            frequency: bodyShelfFrequency,
            gainDB: bodyShelfGainDB
        )
        lowerMidDip = Biquad.peaking(
            sampleRate: sampleRate,
            frequency: lowerMidFrequency,
            gainDB: lowerMidGainDB,
            q: lowerMidQ
        )
    }

    public mutating func reset() {
        bodyShelf.reset()
        lowerMidDip.reset()
    }

    public mutating func process(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        var output: [Int16] = []
        output.reserveCapacity(samples.count)
        for sample in samples {
            var value = bodyShelf.process(Double(sample))
            value = lowerMidDip.process(value)
            output.append(Int16(clamping: Int(value.rounded())))
        }
        return output
    }
}

private struct Biquad: Sendable {
    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double
    private var input1 = 0.0
    private var input2 = 0.0
    private var output1 = 0.0
    private var output2 = 0.0

    static func lowPass(
        sampleRate: Double,
        cutoff: Double,
        q: Double = 1.0 / sqrt(2.0)
    ) -> Self {
        coefficients(
            sampleRate: sampleRate,
            cutoff: cutoff,
            q: q,
            highPass: false
        )
    }

    static func highPass(
        sampleRate: Double,
        cutoff: Double,
        q: Double = 1.0 / sqrt(2.0)
    ) -> Self {
        coefficients(
            sampleRate: sampleRate,
            cutoff: cutoff,
            q: q,
            highPass: true
        )
    }

    /// Robert Bristow-Johnson low-shelf biquad. A 0 dB shelf naturally
    /// reduces to an identity filter, which also makes reference testing
    /// straightforward.
    static func lowShelf(
        sampleRate: Double,
        frequency: Double,
        gainDB: Double,
        q: Double = 0.7
    ) -> Self {
        let safeRate = max(sampleRate, 1)
        let safeFrequency = min(max(frequency, 1), safeRate * 0.49)
        let omega = 2.0 * Double.pi * safeFrequency / safeRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2.0 * max(q, 0.01))
        let amplitude = pow(10.0, gainDB / 40.0)
        let beta = 2.0 * sqrt(amplitude) * alpha
        let amplitudePlusOne = amplitude + 1.0
        let amplitudeMinusOne = amplitude - 1.0

        let a0 = amplitudePlusOne
            + amplitudeMinusOne * cosine
            + beta
        return Self(
            b0: amplitude * (
                amplitudePlusOne
                    - amplitudeMinusOne * cosine
                    + beta
            ) / a0,
            b1: 2.0 * amplitude * (
                amplitudeMinusOne
                    - amplitudePlusOne * cosine
            ) / a0,
            b2: amplitude * (
                amplitudePlusOne
                    - amplitudeMinusOne * cosine
                    - beta
            ) / a0,
            a1: -2.0 * (
                amplitudeMinusOne
                    + amplitudePlusOne * cosine
            ) / a0,
            a2: (
                amplitudePlusOne
                    + amplitudeMinusOne * cosine
                    - beta
            ) / a0
        )
    }

    /// Robert Bristow-Johnson peaking EQ. Negative gain creates a smooth,
    /// bounded dip without the ringing of a narrow notch filter.
    static func peaking(
        sampleRate: Double,
        frequency: Double,
        gainDB: Double,
        q: Double
    ) -> Self {
        let safeRate = max(sampleRate, 1)
        let safeFrequency = min(max(frequency, 1), safeRate * 0.49)
        let amplitude = pow(10.0, gainDB / 40.0)
        let omega = 2.0 * Double.pi * safeFrequency / safeRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2.0 * max(q, 0.01))
        let a0 = 1.0 + alpha / amplitude
        return Self(
            b0: (1.0 + alpha * amplitude) / a0,
            b1: -2.0 * cosine / a0,
            b2: (1.0 - alpha * amplitude) / a0,
            a1: -2.0 * cosine / a0,
            a2: (1.0 - alpha / amplitude) / a0
        )
    }

    private static func coefficients(
        sampleRate: Double,
        cutoff: Double,
        q: Double,
        highPass: Bool
    ) -> Self {
        let safeRate = max(sampleRate, 1)
        let safeCutoff = min(max(cutoff, 1), safeRate * 0.49)
        let omega = 2.0 * Double.pi * safeCutoff / safeRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2.0 * max(q, 0.01))
        let a0 = 1.0 + alpha
        let numerator = highPass ? 1.0 + cosine : 1.0 - cosine
        let sign = highPass ? -1.0 : 1.0
        return Self(
            b0: numerator * 0.5 / a0,
            b1: sign * numerator / a0,
            b2: numerator * 0.5 / a0,
            a1: -2.0 * cosine / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    mutating func reset() {
        input1 = 0
        input2 = 0
        output1 = 0
        output2 = 0
    }

    mutating func process(_ input: Double) -> Double {
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
