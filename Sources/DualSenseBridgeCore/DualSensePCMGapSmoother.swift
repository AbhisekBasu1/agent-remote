import Foundation

/// Removes the hard signal-to-zero edges produced when a sparse Bluetooth
/// stream temporarily underruns its output buffer. It does not invent speech:
/// a short raised-cosine ramp only softens the edge into and out of silence.
public struct DualSensePCMGapSmoother: Sendable {
    private enum Phase: Sendable {
        case signal
        case fadingOut
        case gap
        case fadingIn
    }

    private let fadeFrames: Int
    private var phase: Phase = .gap
    private var fadePosition = 0
    private var fadeStart: Float = 0
    private var lastOutput: Float = 0

    public init(fadeFrames: Int = 96) {
        self.fadeFrames = max(fadeFrames, 1)
    }

    public mutating func reset() {
        phase = .gap
        fadePosition = 0
        fadeStart = 0
        lastOutput = 0
    }

    /// Pass a sample while buffered audio is available, or `nil` during an
    /// underrun. The returned sample is always suitable for immediate output.
    public mutating func render(_ sample: Int16?) -> Int16 {
        let output: Float
        switch (phase, sample) {
        case (.signal, .some(let sample)):
            output = Float(sample)

        case (.signal, .none):
            beginFadeOut()
            output = fadeOutSample()

        case (.fadingOut, .none):
            output = fadeOutSample()

        case (.fadingOut, .some(let sample)):
            beginFadeIn()
            output = fadeInSample(toward: Float(sample))

        case (.gap, .none):
            output = 0

        case (.gap, .some(let sample)):
            beginFadeIn()
            output = fadeInSample(toward: Float(sample))

        case (.fadingIn, .some(let sample)):
            output = fadeInSample(toward: Float(sample))

        case (.fadingIn, .none):
            beginFadeOut()
            output = fadeOutSample()
        }

        lastOutput = output
        return Int16(clamping: Int(output.rounded()))
    }

    private mutating func beginFadeOut() {
        phase = .fadingOut
        fadePosition = 0
        fadeStart = lastOutput
    }

    private mutating func beginFadeIn() {
        phase = .fadingIn
        fadePosition = 0
        fadeStart = lastOutput
    }

    private mutating func fadeOutSample() -> Float {
        fadePosition += 1
        let progress = min(Float(fadePosition) / Float(fadeFrames), 1)
        let weight = 0.5 + 0.5 * cos(.pi * progress)
        let output = fadeStart * weight
        if fadePosition >= fadeFrames {
            phase = .gap
            fadePosition = 0
            fadeStart = 0
        }
        return output
    }

    private mutating func fadeInSample(toward sample: Float) -> Float {
        fadePosition += 1
        let progress = min(Float(fadePosition) / Float(fadeFrames), 1)
        let weight = 0.5 - 0.5 * cos(.pi * progress)
        let output = fadeStart * (1 - weight) + sample * weight
        if fadePosition >= fadeFrames {
            phase = .signal
            fadePosition = 0
            fadeStart = 0
        }
        return output
    }
}
