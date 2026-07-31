import CSonic
import Foundation

/// Streaming, pitch-preserving speech expansion backed by the Apache-2.0
/// Sonic library. Sonic finds and overlaps complete pitch periods, which is a
/// better fit for the DualSense's compacted speech than resampling or a
/// phase-vocoder. `timeRatio` is output duration divided by input duration.
public final class DualSenseSonicSpeechTimeStretcher {
    private static let sampleRate: Int32 = 48_000
    private static let channelCount: Int32 = 1

    public private(set) var timeRatio: Double
    private let quality: Int32
    private var stream: OpaquePointer

    public init(timeRatio: Double = 2.30, quality: Int32 = 1) {
        self.timeRatio = Self.validated(timeRatio)
        self.quality = quality == 0 ? 0 : 1
        guard let stream = sonicCreateStream(
            Self.sampleRate,
            Self.channelCount
        ) else {
            fatalError("Sonic could not allocate a speech stream")
        }
        self.stream = stream
        configureStream()
    }

    deinit {
        sonicDestroyStream(stream)
    }

    /// Updates the ratio for the next speech session. Live callers deliberately
    /// keep this fixed for an entire utterance so words cannot change speed as
    /// the Bluetooth counter estimate converges.
    public func setTimeRatio(_ timeRatio: Double) {
        self.timeRatio = Self.validated(timeRatio)
        sonicSetSpeed(stream, Float(1.0 / self.timeRatio))
    }

    public func process(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        let succeeded = samples.withUnsafeBufferPointer { buffer in
            sonicWriteShortToStream(
                stream,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard succeeded != 0 else { return [] }
        return drainAvailableSamples()
    }

    /// Emits Sonic's short analysis tail. Flushing is intended for completed
    /// files and tests; the live path naturally feeds the controller's release
    /// silence through the stream before resetting it.
    public func flush() -> [Int16] {
        guard sonicFlushStream(stream) != 0 else { return [] }
        return drainAvailableSamples()
    }

    public func reset() {
        sonicDestroyStream(stream)
        guard let replacement = sonicCreateStream(
            Self.sampleRate,
            Self.channelCount
        ) else {
            fatalError("Sonic could not reset its speech stream")
        }
        stream = replacement
        configureStream()
    }

    private func configureStream() {
        sonicSetQuality(stream, quality)
        sonicSetSpeed(stream, Float(1.0 / timeRatio))
    }

    private func drainAvailableSamples() -> [Int16] {
        var output: [Int16] = []
        while true {
            let available = Int(sonicSamplesAvailable(stream))
            guard available > 0 else { break }
            var chunk = [Int16](repeating: 0, count: available)
            let readCount = chunk.withUnsafeMutableBufferPointer { buffer in
                Int(sonicReadShortFromStream(
                    stream,
                    buffer.baseAddress,
                    Int32(buffer.count)
                ))
            }
            guard readCount > 0 else { break }
            output.append(contentsOf: chunk.prefix(readCount))
        }
        return output
    }

    private static func validated(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 2.30 }
        return min(max(ratio, 1.0), 4.0)
    }
}
